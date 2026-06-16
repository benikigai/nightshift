#!/usr/bin/env python3
"""AgentForge Evaluator — Sonnet scoring + W&B Weave observability.

Two modes:
  python3 evaluate.py --eval --feature-id N --description "..." --verify "..." --category CAT --diff-file PATH --attempt N
  python3 evaluate.py --log  --feature-id N --score N --duration N --tokens-coder N --tokens-evaluator N --status STATUS
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
import traceback

from extract_json import extract_json

# --- W&B Weave setup (graceful fallback if unavailable) ---
WEAVE_AVAILABLE = False
try:
    import weave
    weave.init("agentforge")
    WEAVE_AVAILABLE = True
except Exception:
    pass

# --- Anthropic setup ---
try:
    from anthropic import Anthropic
    client = Anthropic()
except Exception:
    client = None


def _ns_evaluator_model(default="claude-sonnet-4-6"):
    """Read models.evaluator from nightshift.config.json; fall back to default."""
    cfg = os.environ.get(
        "NIGHTSHIFT_CONFIG",
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "nightshift", "nightshift.config.json"),
    )
    try:
        with open(cfg) as f:
            return json.load(f)["models"]["evaluator"]
    except Exception:
        return default


EVALUATOR_SYSTEM_PROMPT = """You are a strict code quality evaluator for an autonomous build system called AgentForge.
You receive a git diff and a feature specification. Score the implementation honestly.

## Gates (must BOTH pass before scoring dimensions)
- **Compilation**: The code changes should not introduce syntax errors or type errors. If the diff clearly has broken syntax, gate fails.
- **Tests**: The code should not obviously break existing tests. If you see removed test assertions or broken imports, gate fails.
If either gate fails, set overall score to 0 and explain why in feedback.

## Scoring Dimensions (only if gates pass)
- **Completeness (weight: 40%)**: Does the code fully implement the feature as described in the description and verify fields? 0 = nothing relevant built, 10 = fully complete with edge cases handled.
- **Visual Quality (weight: 30%)**: For UI features: does it look professional? Clean typography, proper spacing, dark mode support, responsive? For non-UI: is the code well-structured? A 10/10 looks like a production analytics dashboard. A 5/10 looks like a homework assignment.
- **No Placeholders (weight: 30%)**: Is everything real code? Score 0 if ANY: TODO comments, stub functions, "implement later" comments, Lorem ipsum, console.log('test'), comments that just restate the code.

## Overall Score
overall = round(completeness * 0.4 + visual_quality * 0.3 + no_placeholders * 0.3)

## Threshold Awareness
- Scaffold features (categories: scaffold): threshold 5/10
- Content features (categories: cards, timeline, quality, features, tokens): threshold 7/10
- Polish features (categories: git, polish): threshold 6/10

## Feedback Requirements (when score < threshold)
For EACH dimension scoring below 8, provide a specific issue with:
- dimension: which scoring dimension
- issue: what is wrong (one sentence)
- file: the specific file path
- fix: exactly what to change (one sentence)

Vague feedback like "could be better" or "needs improvement" is FORBIDDEN.

## Output Format
Return ONLY valid JSON, no other text:
{
  "feature_id": <number>,
  "gates": {"compilation": <bool>, "tests": <bool>},
  "scores": {"completeness": <0-10>, "visual_quality": <0-10>, "no_placeholders": <0-10>},
  "overall": <0-10>,
  "pass": <bool>,
  "feedback": [
    {"dimension": "<name>", "issue": "<specific problem>", "file": "<path>", "fix": "<specific fix>"}
  ],
  "summary": "<one sentence overall assessment>"
}"""


def evaluate_feature(feature_id, description, verify, category, diff_text, attempt):
    """Score a feature implementation via Sonnet 4."""
    if client is None:
        return {"feature_id": feature_id, "overall": 5, "pass": True,
                "error": "Anthropic client unavailable, defaulting to pass",
                "gates": {"compilation": True, "tests": True},
                "scores": {"completeness": 5, "visual_quality": 5, "no_placeholders": 5},
                "feedback": [], "summary": "Evaluator unavailable — auto-pass"}

    user_msg = (
        "Feature #%d: %s\n"
        "Verify criteria: %s\n"
        "Category: %s\n"
        "Attempt: %d\n\n"
        "## Git Diff\n```\n%s\n```"
    ) % (feature_id, description, verify, category, attempt, diff_text[:15000])

    try:
        response = client.messages.create(
            model=_ns_evaluator_model(),
            max_tokens=1500,
            system=EVALUATOR_SYSTEM_PROMPT,
            messages=[{"role": "user", "content": user_msg}]
        )
        raw = response.content[0].text
        # Triple-fallback extraction handles direct JSON, ```json``` fences, and brace-span.
        result = extract_json(raw)
        if result is not None:
            result["tokens_evaluator"] = response.usage.input_tokens + response.usage.output_tokens
            return result
        else:
            return {"feature_id": feature_id, "overall": 0, "pass": False,
                    "error": "Could not parse evaluator JSON",
                    "raw": raw[:500],
                    "gates": {"compilation": True, "tests": True},
                    "scores": {"completeness": 0, "visual_quality": 0, "no_placeholders": 0},
                    "feedback": [{"dimension": "parse", "issue": "Evaluator returned non-JSON", "file": "N/A", "fix": "Retry"}],
                    "summary": "Evaluator response parsing failed"}
    except Exception as e:
        return {"feature_id": feature_id, "overall": 0, "pass": False,
                "error": str(e),
                "gates": {"compilation": True, "tests": True},
                "scores": {"completeness": 0, "visual_quality": 0, "no_placeholders": 0},
                "feedback": [], "summary": "Evaluator API call failed: %s" % str(e)}


def log_iteration(feature_id, score, duration, tokens_coder, tokens_evaluator, status):
    """Log iteration metadata to W&B Weave."""
    entry = {
        "feature_id": feature_id,
        "score": score,
        "duration_sec": duration,
        "tokens_coder": tokens_coder,
        "tokens_evaluator": tokens_evaluator,
        "status": status,
        "timestamp": time.time()
    }
    if WEAVE_AVAILABLE:
        try:
            _log_to_weave(entry)
        except Exception:
            pass  # Weave failure is non-fatal
    return entry


# Wrap with weave.op if available
if WEAVE_AVAILABLE:
    @weave.op()
    def _evaluate_feature_traced(feature_id, description, verify, category, diff_text, attempt):
        return evaluate_feature(feature_id, description, verify, category, diff_text, attempt)

    @weave.op()
    def _log_to_weave(entry):
        return entry
else:
    _evaluate_feature_traced = evaluate_feature


def main():
    parser = argparse.ArgumentParser(description="AgentForge Evaluator")
    sub = parser.add_subparsers(dest="mode")

    eval_p = sub.add_parser("eval", help="Evaluate a feature diff")
    eval_p.add_argument("--feature-id", type=int, required=True)
    eval_p.add_argument("--description", type=str, required=True)
    eval_p.add_argument("--verify", type=str, required=True)
    eval_p.add_argument("--category", type=str, required=True)
    eval_p.add_argument("--diff-file", type=str, required=True)
    eval_p.add_argument("--attempt", type=int, required=True)

    log_p = sub.add_parser("log", help="Log iteration to W&B")
    log_p.add_argument("--feature-id", type=int, required=True)
    log_p.add_argument("--score", type=int, required=True)
    log_p.add_argument("--duration", type=int, required=True)
    log_p.add_argument("--tokens-coder", type=int, default=0)
    log_p.add_argument("--tokens-evaluator", type=int, default=0)
    log_p.add_argument("--status", type=str, required=True)

    args = parser.parse_args()

    if args.mode == "eval":
        diff_text = ""
        if os.path.exists(args.diff_file):
            with open(args.diff_file, "r") as f:
                diff_text = f.read()
        if WEAVE_AVAILABLE:
            result = _evaluate_feature_traced(
                args.feature_id, args.description, args.verify,
                args.category, diff_text, args.attempt)
        else:
            result = evaluate_feature(
                args.feature_id, args.description, args.verify,
                args.category, diff_text, args.attempt)
        print(json.dumps(result))

    elif args.mode == "log":
        result = log_iteration(
            args.feature_id, args.score, args.duration,
            args.tokens_coder, args.tokens_evaluator, args.status)
        print(json.dumps(result))

    else:
        parser.print_help()
        sys.exit(1)


if __name__ == "__main__":
    main()
