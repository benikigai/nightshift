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

slog() { printf '[supervisor %s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" | tee -a "$SUP_LOG"; }

write_checkpoint() {  # write_checkpoint <phase> [shift]
    python3 - "$CHECKPOINT" "$1" "${2:-}" <<'PY' 2>/dev/null || true
import json, os, sys
out, phase, shift = sys.argv[1], sys.argv[2], sys.argv[3]
json.dump({"phase": phase, "shift": shift, "pid": os.getpid()}, open(out, "w"), indent=2)
PY
}

shutdown() { slog "SIGTERM/SIGINT received — graceful shutdown"; write_checkpoint "stopped"; exit 0; }
trap shutdown TERM INT

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
        bash "$SUP_DIR/dispatch.sh" once
        rc=$?
        if [ "$rc" -eq 10 ]; then
            if [ "$drain" = "drain" ]; then slog "queue empty — drain-once complete"; write_checkpoint "drained"; return 0; fi
            write_checkpoint "idle"
            sleep "$IDLE"
        fi
    done
}

slog "supervisor starting (queue=$QUEUE, idle=${IDLE}s)"
recover_orphans
case "${1:-daemon}" in
    --drain-once) run_loop drain ;;
    daemon|"")    run_loop ;;
    *) echo "usage: nightshift-supervisor.sh [--drain-once]" >&2; exit 2 ;;
esac
