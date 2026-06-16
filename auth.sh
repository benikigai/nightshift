#!/usr/bin/env bash
# nightshift/auth.sh — subscription-first auth resolver for Nightshift adapters.
#
# Source this file, then run subscription CLIs via ns_run_subscription so that
# metered API keys are STRIPPED from the environment (forcing Claude Max / ChatGPT /
# Google OAuth subscription billing instead of pay-per-token API).
#
# Metered fallback is opt-in only: ns_fallback_enabled gates it on auth.fallback_api,
# and the dispatcher/circuit-breaker (Task 8) decides WHEN to fall back (on a rate-limit
# signal). This file never stores, logs, or echoes key material.

NS_AUTH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS_CONFIG="${NIGHTSHIFT_CONFIG:-$NS_AUTH_DIR/nightshift.config.json}"

# ns_cfg <dotted.key> <default> — prints config value, or default on any failure.
ns_cfg() {
    python3 - "$NS_CONFIG" "$1" "$2" <<'PY' 2>/dev/null || echo "$2"
import json, sys
cfg, key, default = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    d = json.load(open(cfg))
    for p in [x for x in key.split('.') if x]:
        d = d[p]
    print(d)
except Exception:
    print(default)
PY
}

# ns_fallback_enabled — exit 0 iff auth.fallback_api is true in config.
ns_fallback_enabled() {
    case "$(ns_cfg auth.fallback_api false)" in
        True|true|1) return 0 ;;
        *) return 1 ;;
    esac
}

# ns_run_subscription <cmd...> — run a command with ALL metered provider keys stripped,
# forcing subscription/OAuth auth. Returns the command's exit code.
ns_run_subscription() {
    env -u ANTHROPIC_API_KEY \
        -u OPENAI_API_KEY \
        -u GEMINI_API_KEY \
        -u GOOGLE_API_KEY \
        -u GOOGLE_GENAI_API_KEY \
        -u GOOGLE_APPLICATION_CREDENTIALS \
        "$@"
}

# ns_run_metered <cmd...> — RESERVED for a future metered-fallback task. Runs a command WITH
# whatever keys are in the env (metered). NOT WIRED YET: auth.fallback_api defaults false, so the
# loop is subscription-only and the breaker HALTS on subscription exhaustion rather than falling
# back. Wiring this requires per-provider rate-limit detection + telemetry auth_path=fallback +
# real cost_usd so guard.py's budget ledger (daily + per_run) actually engages.
ns_run_metered() {
    "$@"
}
