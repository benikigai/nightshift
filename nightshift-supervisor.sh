#!/usr/bin/env bash
# nightshift/nightshift-supervisor.sh — the always-on supervisor.
#
# Recovers crash-orphaned shifts, then loops the dispatcher forever, checkpointing
# progress and shutting down gracefully on SIGTERM/SIGINT. Re-execs under `caffeinate`
# so the Mac never sleeps mid-shift. Activate via launchd (Task 14) — KeepAlive restarts
# it on crash; recovery + the build's per-feature `passes` flags prevent duplicate work.
#
# Modes:
#   nightshift-supervisor.sh              # daemon: recover, then loop forever
#   nightshift-supervisor.sh --drain-once # recover, drain the queue, exit (test/manual)
set -uo pipefail

SUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SUP_DIR/auth.sh"

QUEUE="${NIGHTSHIFT_QUEUE:-$SUP_DIR/queue}"
STATE="${NIGHTSHIFT_STATE:-$SUP_DIR/state}"
CHECKPOINT="$STATE/checkpoint.json"
SUP_LOG="$STATE/supervisor.log"
IDLE="${NS_IDLE_SECONDS:-30}"
mkdir -p "$QUEUE"/pending "$QUEUE"/active "$QUEUE"/done "$QUEUE"/failed "$STATE"

# Re-exec under caffeinate so the machine stays awake (skip if already wrapped or disabled).
if [ -z "${NS_CAFFEINATED:-}" ] && [ -z "${NS_NO_CAFFEINATE:-}" ] && command -v caffeinate >/dev/null 2>&1; then
    exec caffeinate -s env NS_CAFFEINATED=1 "$0" "$@"
fi

# Load daemon secrets (e.g. CLAUDE_CODE_OAUTH_TOKEN for headless Claude Max) — kept OUT of the
# launchd plist and out of git. auth.sh strips metered API keys but preserves this token.
NS_SECRETS="${NIGHTSHIFT_SECRETS:-$HOME/.config/nightshift/secrets.env}"
# shellcheck source=/dev/null
[ -f "$NS_SECRETS" ] && . "$NS_SECRETS"

slog() { printf '[supervisor %s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" | tee -a "$SUP_LOG"; }

prune_logs() {  # rotate: drop per-shift logs older than retention so $STATE can't grow unbounded
    find "$STATE/logs" -type f -name '*.log' -mtime +"${NS_LOG_RETAIN_DAYS:-14}" -delete 2>/dev/null || true
}

HALT_BACKOFF="${NS_HALT_BACKOFF:-600}"   # when the breaker is OPEN, stay up and re-check this often
LOCK="$STATE/supervisor.lock"
DISPATCH_PID=""

write_checkpoint() {  # write_checkpoint <phase> [shift]
    python3 - "$CHECKPOINT" "$1" "${2:-}" <<'PY' 2>/dev/null || true
import json, os, sys
out, phase, shift = sys.argv[1], sys.argv[2], sys.argv[3]
json.dump({"phase": phase, "shift": shift, "pid": os.getpid()}, open(out, "w"), indent=2)
PY
}

release_lock() { rm -rf "$LOCK" 2>/dev/null || true; }

acquire_lock() {  # single-instance guard (atomic mkdir); reclaim a lock held by a dead pid
    if mkdir "$LOCK" 2>/dev/null; then echo $$ > "$LOCK/pid"; return 0; fi
    local opid; opid="$(cat "$LOCK/pid" 2>/dev/null || echo "")"
    if [ -n "$opid" ] && kill -0 "$opid" 2>/dev/null; then
        slog "another supervisor (pid $opid) holds the lock — exiting"
        return 1
    fi
    slog "reclaiming stale supervisor lock (was pid ${opid:-unknown})"
    rm -rf "$LOCK"
    if mkdir "$LOCK" 2>/dev/null; then echo $$ > "$LOCK/pid"; return 0; fi
    return 1
}

shutdown() {
    slog "SIGTERM/SIGINT received — graceful shutdown"
    if [ -n "${DISPATCH_PID:-}" ] && kill -0 "$DISPATCH_PID" 2>/dev/null; then
        slog "forwarding TERM to in-flight dispatch (pid $DISPATCH_PID) and waiting"
        kill -TERM "$DISPATCH_PID" 2>/dev/null || true
        wait "$DISPATCH_PID" 2>/dev/null || true
    fi
    write_checkpoint "stopped"
    release_lock
    exit 0
}
trap shutdown TERM INT
trap release_lock EXIT

# Crash recovery: any shift left in active/ was interrupted (e.g. kill -9). Re-enqueue it.
recover_orphans() {
    local f name recovered=0
    for f in "$QUEUE"/active/*.shift.json; do
        [ -e "$f" ] || continue
        name="$(basename "$f")"
        if mv "$f" "$QUEUE/pending/$name"; then
            slog "recovered orphaned shift -> pending: $name"
            write_checkpoint "recovered" "$name"
            recovered=$((recovered + 1))
        fi
    done
    [ "$recovered" -eq 0 ] && slog "no orphaned shifts to recover"
}

run_loop() {  # run_loop [drain]
    local drain="${1:-}"
    while true; do
        write_checkpoint "dispatching"
        # run dispatch as a child so SIGTERM can be forwarded within launchd's grace window
        bash "$SUP_DIR/dispatch.sh" once & DISPATCH_PID=$!
        wait "$DISPATCH_PID"; rc=$?
        DISPATCH_PID=""
        case "$rc" in
            11)  # breaker OPEN / budget halt — STAY UP and idle so launchd KeepAlive never flaps;
                 # re-check after a backoff. The breaker emits its alert once, on the OPEN edge.
                write_checkpoint "halted"
                if [ "$drain" = "drain" ]; then slog "halted by guardrail — drain-once stops (reset: guard.py breaker-reset)"; return 0; fi
                slog "halted by guardrail — backing off ${HALT_BACKOFF}s, then re-checking (reset: guard.py breaker-reset)"
                sleep "$HALT_BACKOFF"
                ;;
            12)  # rate-limited this hour
                write_checkpoint "rate_limited"
                [ "$drain" = "drain" ] && { slog "rate-limited — drain-once stops"; return 0; }
                sleep "$IDLE"
                ;;
            13)  # review requeued the shift — pace before re-claiming so it doesn't hot-loop
                write_checkpoint "requeued"
                [ "$drain" = "drain" ] || sleep "$IDLE"
                ;;
            14)  # review escalated to failed/ — move on
                slog "shift escalated to failed/ — continuing"
                ;;
            10)  # queue empty
                if [ "$drain" = "drain" ]; then slog "queue empty — drain-once complete"; write_checkpoint "drained"; return 0; fi
                write_checkpoint "idle"
                sleep "$IDLE"
                ;;
            *)   # processed a shift (0 or build rc); continue
                : ;;
        esac
    done
}

slog "supervisor starting (queue=$QUEUE, idle=${IDLE}s)"
acquire_lock || exit 0
prune_logs
recover_orphans
case "${1:-daemon}" in
    --drain-once) run_loop drain ;;
    daemon|"")    run_loop ;;
    *) echo "usage: nightshift-supervisor.sh [--drain-once]" >&2; exit 2 ;;
esac
