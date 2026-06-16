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

process_one() {
    local active name adapter workdir logf rc
    active="$(claim_oldest)" || return 10
    name="$(basename "$active")"
    adapter="$(ns_cfg default_adapter codex)"
    workdir="${NIGHTSHIFT_WORKDIR:-$(ns_cfg paths.graveyard "$SUP_DIR/../graveyard")}"
    logf="$LOGS/${name%.json}.$(date '+%Y%m%dT%H%M%S').log"
    log "processing $name via '$adapter' adapter (workdir=$workdir)"
    bash "$SUP_DIR/adapters/$adapter.sh" build --features "$active" --workdir "$workdir" >"$logf" 2>&1
    rc=$?
    if [ "$rc" -eq 0 ]; then
        mv "$active" "$QUEUE/done/$name"
        log "DONE $name (log: $logf)"
    else
        mv "$active" "$QUEUE/failed/$name"
        log "FAILED $name rc=$rc (log: $logf)"
    fi
    return "$rc"
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
