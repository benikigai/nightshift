#!/usr/bin/env bash
# nightshift/notify-telegram.sh <title> <message>
# Adapter for guard.py's NIGHTSHIFT_NOTIFY_CMD -> the existing Forge notifier
# (~/.openclaw/forge/notify.sh: Discord #system-ops + Telegram Forge-bot, chat 5611660528).
# guard.py calls this with exactly two args (title, message); we forward as an "error"-level alert.
set -uo pipefail
TITLE="${1:-Nightshift}"; MSG="${2:-}"
FWD="${NIGHTSHIFT_FORGE_NOTIFY:-$HOME/.openclaw/forge/notify.sh}"
if [ -x "$FWD" ]; then
    exec "$FWD" error "🌙 Nightshift — ${TITLE}: ${MSG}"
fi
# fallback: the forge notifier isn't present — record locally so the alert isn't lost
echo "$(date '+%FT%T') | ${TITLE} | ${MSG}" >> "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/state/notifications.log"
