#!/usr/bin/env bash
# nightshift/dispatch.sh — pull shifts from the queue and run them through the build adapter.
#
# Queue layout (under $NIGHTSHIFT_QUEUE, default nightshift/queue):
#   pending/  — *.shift.json awaiting work, processed oldest-first (mtime)
#   active/   — the shift currently being built (at most one per dispatcher)
#   done/     — builds that exited 0
#   failed/   — builds that exited non-zero
#
# Concurrency: the "pull" is an atomic `mv` (pending -> active). macOS has no flock, and
# atomic rename is a stronger guarantee anyway — only one dispatcher can win a given file,
# so two dispatchers never process the same shift.
#
# Usage:
#   dispatch.sh once     # process the single oldest pending shift, then exit
#   dispatch.sh --drain  # loop until the queue is empty
# Exit: 0 processed-ok | non-zero build rc | 10 queue-empty (once mode)
set -uo pipefail

SUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SUP_DIR/auth.sh"

QUEUE="${NIGHTSHIFT_QUEUE:-$SUP_DIR/queue}"
STATE="${NIGHTSHIFT_STATE:-$SUP_DIR/state}"
LOGS="$STATE/logs"
mkdir -p "$QUEUE"/pending "$QUEUE"/active "$QUEUE"/done "$QUEUE"/failed "$LOGS"

log() { printf '[dispatch %s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*"; }

# claim_oldest — atomically move the oldest pending shift to active/; echo its active path.
claim_oldest() {
    local f name
    for f in $(ls -1tr "$QUEUE"/pending/*.shift.json 2>/dev/null); do
        name="$(basename "$f")"
        if mv "$f" "$QUEUE/active/$name" 2>/dev/null; then
            echo "$QUEUE/active/$name"
            return 0
        fi
        # lost the race to another dispatcher; try the next candidate
    done
    return 1
}

# review_phase <name> <workdir> — post-build Handoff review.
# Returns: 0 approved | 13 re-queued with recovery hint | 14 escalated (give up).
review_phase() {
    local name="$1" workdir="$2" verdict hint cycle cyclefile
    verdict="$(bash "$SUP_DIR/handoff.sh" review --workdir "$workdir" 2>/dev/null | tail -1)"
    [ -n "$verdict" ] || verdict="BLOCK"
    log "review verdict for $name: $verdict"
    if [ "$verdict" = "APPROVE" ]; then
        bash "$SUP_DIR/handoff.sh" pr --workdir "$workdir" >/dev/null 2>&1 || true
        return 0
    fi
    cyclefile="$STATE/recovery/$name.count"
    cycle="$(cat "$cyclefile" 2>/dev/null || echo 0)"; cycle=$((cycle + 1))
    if [ "$cycle" -ge 2 ]; then
        python3 "$SUP_DIR/guard.py" notify "Nightshift ESCALATION" \
            "$name failed review after $cycle cycles ($verdict) — needs a human" >/dev/null 2>&1 || true
        return 14
    fi
    mkdir -p "$STATE/recovery"; echo "$cycle" > "$cyclefile"
    hint="$(bash "$SUP_DIR/handoff.sh" triage --workdir "$workdir" 2>/dev/null)"
    [ -n "$hint" ] || hint="Address the review findings."
    mkdir -p "$workdir/.ralph-logs"
    printf '## Recovery hint (review cycle %s, verdict %s)\n%s\n\n' "$cycle" "$verdict" "$hint" >> "$workdir/.ralph-logs/feedback.md"
    log "re-queueing $name with recovery hint (cycle $cycle)"
    return 13
}

process_one() {
    local active name adapter workdir logf rc
    local GUARD="$SUP_DIR/guard.py"
    # --- guardrails: refuse to dispatch when halted ---
    if python3 "$GUARD" breaker-open 2>/dev/null; then
        python3 "$GUARD" notify "Nightshift HALTED" "circuit breaker OPEN: $(python3 "$GUARD" breaker-reason 2>/dev/null)" >/dev/null 2>&1
        log "HALT: circuit breaker OPEN — not dispatching (reset: guard.py breaker-reset)"
        return 11
    fi
    if python3 "$GUARD" budget-exceeded 2>/dev/null; then
        python3 "$GUARD" notify "Nightshift HALTED" "daily metered budget exceeded" >/dev/null 2>&1
        log "HALT: daily metered budget exceeded — not dispatching"
        return 11
    fi
    if python3 "$GUARD" rate-exceeded 2>/dev/null; then
        log "rate limit reached this hour — waiting"
        return 12
    fi
    active="$(claim_oldest)" || return 10
    name="$(basename "$active")"
    adapter="$(ns_cfg default_adapter codex)"
    logf="$LOGS/${name%.json}.$(date '+%Y%m%dT%H%M%S').log"

    # --- workdir: isolated git worktree per shift (T10), falling back to the shared base dir ---
    local base worktree="" ws br t pv dest ret=0
    base="${NIGHTSHIFT_WORKDIR:-$(ns_cfg paths.graveyard "$SUP_DIR/../graveyard")}"
    workdir="$base"
    case "$(ns_cfg worktrees.enabled true)" in
        True|true|1)
            if git -C "$base" rev-parse --git-dir >/dev/null 2>&1; then
                ws="$STATE/worktrees/${name%.shift.json}"; br="nightshift/${name%.shift.json}"
                git -C "$base" worktree remove --force "$ws" >/dev/null 2>&1 || true
                rm -rf "$ws" 2>/dev/null || true
                for t in 1 2 3 4; do
                    if git -C "$base" worktree add -f "$ws" -b "$br" >/dev/null 2>&1 \
                       || git -C "$base" worktree add -f "$ws" "$br" >/dev/null 2>&1; then
                        worktree="$ws"; workdir="$ws"; break
                    fi
                    sleep 0.3
                done
            fi
            ;;
    esac

    # --- inject prior failed approaches for this shift (hypothesis memory, T10) ---
    python3 "$SUP_DIR/memory.py" inject "$name" "$workdir" >/dev/null 2>&1 || true

    python3 "$GUARD" rate-record >/dev/null 2>&1 || true
    log "processing $name via '$adapter' adapter (workdir=$workdir)"
    bash "$SUP_DIR/adapters/$adapter.sh" build --features "$active" --workdir "$workdir" >"$logf" 2>&1
    rc=$?
    python3 "$GUARD" ingest-telemetry "$workdir/telemetry.json" "$rc" >/dev/null 2>&1 || true

    # --- route outcome + record to hypothesis memory ---
    if [ "$rc" -ne 0 ]; then
        dest="failed"; ret="$rc"
        python3 "$SUP_DIR/memory.py" record "$name" failed "build rc=$rc" >/dev/null 2>&1 || true
        log "FAILED $name rc=$rc (log: $logf)"
    else
        case "$(ns_cfg review.enabled true)" in
            True|true|1)
                review_phase "$name" "$workdir"; pv=$?
                case "$pv" in
                    0)  dest="done";    rm -f "$STATE/recovery/$name.count"; python3 "$SUP_DIR/memory.py" record "$name" done >/dev/null 2>&1 || true; log "DONE+APPROVED $name" ;;
                    13) dest="pending"; python3 "$SUP_DIR/memory.py" record "$name" blocked "review requeue" >/dev/null 2>&1 || true; log "REQUEUED $name (review)" ;;
                    14) dest="failed";  rm -f "$STATE/recovery/$name.count"; python3 "$SUP_DIR/memory.py" record "$name" blocked "review escalated" >/dev/null 2>&1 || true; log "FAILED+ESCALATED $name (review)" ;;
                esac ;;
            *) dest="done"; rm -f "$STATE/recovery/$name.count"; log "DONE $name (review disabled)" ;;
        esac
    fi

    # --- clean up the worktree (commits persist on the branch, so removal is safe) ---
    if [ -n "$worktree" ]; then
        git -C "$base" worktree remove --force "$worktree" >/dev/null 2>&1 || rm -rf "$worktree"
    fi

    mv "$active" "$QUEUE/$dest/$name"
    return "$ret"
}

MODE="${1:-once}"
case "$MODE" in
    once)
        process_one
        exit $?
        ;;
    --drain|drain)
        while true; do
            process_one
            rc=$?
            if [ "$rc" -eq 10 ]; then log "queue empty — drain complete"; break; fi
        done
        ;;
    *)
        echo "usage: dispatch.sh [once|--drain]" >&2
        exit 2
        ;;
esac
