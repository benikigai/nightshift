#!/usr/bin/env bash
# nightshift/handoff.sh — the review/triage/PR phase, driven by the Handoff repo.
#
# Handoff's /review, /triage, /pr are Claude Code skills, so we invoke them headlessly via
# `claude -p` SUBSCRIPTION-FIRST (keys stripped by ns_run_subscription). Each subcommand is
# overridable for testing via NIGHTSHIFT_REVIEW_CMD / NIGHTSHIFT_TRIAGE_CMD / NIGHTSHIFT_PR_CMD
# (the override is run with the workdir as $1).
#
#   handoff.sh review  --workdir <d>   -> prints APPROVE | REQUEST_CHANGES | BLOCK
#   handoff.sh triage  --workdir <d>   -> prints a one-paragraph recovery hint
#   handoff.sh pr      --workdir <d>   -> opens a PR (only if review.auto_pr=true)
set -uo pipefail

SUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SUP_DIR/auth.sh"
HANDOFF="$(ns_cfg paths.handoff "$SUP_DIR/../handoff")"

sub="${1:-}"; [ $# -gt 0 ] && shift
WORKDIR=""
while [ $# -gt 0 ]; do case "$1" in --workdir) WORKDIR="${2:-}"; shift 2 ;; *) shift ;; esac; done

case "$sub" in
    review)
        if [ -n "${NIGHTSHIFT_REVIEW_CMD:-}" ]; then exec bash -c "$NIGHTSHIFT_REVIEW_CMD" _ "$WORKDIR"; fi
        out="$(cd "$WORKDIR" 2>/dev/null && ns_run_subscription claude -p --output-format text \
            "Run the /review skill from $HANDOFF on the current branch's git diff vs main. On the LAST line print exactly one token: APPROVE, REQUEST_CHANGES, or BLOCK." 2>/dev/null)"
        echo "$out" | grep -oE "APPROVE|REQUEST_CHANGES|BLOCK" | tail -1 || echo "BLOCK"
        ;;
    triage)
        if [ -n "${NIGHTSHIFT_TRIAGE_CMD:-}" ]; then exec bash -c "$NIGHTSHIFT_TRIAGE_CMD" _ "$WORKDIR"; fi
        out="$(cd "$WORKDIR" 2>/dev/null && ns_run_subscription claude -p --output-format text \
            "Run /triage from $HANDOFF on the latest failed review. Output ONE short paragraph: a concrete recovery hint for the next build attempt." 2>/dev/null)"
        [ -n "$out" ] && echo "$out" || echo "Address the review findings from the previous attempt."
        ;;
    pr)
        if [ -n "${NIGHTSHIFT_PR_CMD:-}" ]; then exec bash -c "$NIGHTSHIFT_PR_CMD" _ "$WORKDIR"; fi
        case "$(ns_cfg review.auto_pr false)" in
            True|true|1) : ;;
            *) echo "pr: review.auto_pr disabled — leaving the branch for manual PR"; exit 0 ;;
        esac
        (cd "$WORKDIR" 2>/dev/null && ns_run_subscription claude -p \
            "Run /pr from $HANDOFF for the approved review on this branch." ) >/dev/null 2>&1 || true
        echo "pr: opened (auto_pr enabled)"
        ;;
    *)
        echo "usage: handoff.sh review|triage|pr --workdir <d>" >&2
        exit 2
        ;;
esac
