#!/usr/bin/env python3
"""nightshift/memory.py — cross-attempt hypothesis memory.

Records what was tried for each shift and injects prior FAILED approaches into the next
build's feedback so the builder doesn't repeat them (addresses the WRONG_APPROACH loop
that Handoff's /triage classifies).

State: $NIGHTSHIFT_STATE/hypothesis-history.jsonl (append-only).

  memory.py record <shift> <outcome> [approach]   outcome: done|failed|blocked
  memory.py inject <shift> <workdir>              write last 10 failed/blocked approaches
                                                   into <workdir>/.ralph-logs/feedback.md
"""
import datetime
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
STATE = os.environ.get("NIGHTSHIFT_STATE", os.path.join(HERE, "state"))
HIST = os.path.join(STATE, "hypothesis-history.jsonl")


def record(shift, outcome, approach=""):
    os.makedirs(STATE, exist_ok=True)
    rec = {"ts": datetime.datetime.now().isoformat(), "shift": shift,
           "outcome": outcome, "approach": approach}
    with open(HIST, "a") as f:
        f.write(json.dumps(rec) + "\n")
    print("recorded")


def inject(shift, workdir):
    failed = []
    try:
        for line in open(HIST):
            try:
                r = json.loads(line)
            except Exception:
                continue
            if r.get("shift") == shift and r.get("outcome") in ("failed", "blocked"):
                failed.append(r)
    except FileNotFoundError:
        pass
    failed = failed[-10:]
    if not failed:
        print("no prior failures")
        return
    # write to nightshift-memory.md (NOT .ralph-logs/feedback.md, which graveyard.sh blanks);
    # adapters surface this file into the build prompt.
    os.makedirs(workdir, exist_ok=True)
    fb = os.path.join(workdir, "nightshift-memory.md")
    with open(fb, "a") as f:
        f.write("\n## Do NOT repeat these previously-failed approaches for this shift:\n")
        for r in failed:
            f.write("- [%s] %s\n" % (r.get("outcome"), r.get("approach") or "(no detail)"))
    print("injected %d" % len(failed))


def main():
    a = sys.argv[1:]
    if not a:
        sys.stderr.write(__doc__)
        return 2
    if a[0] == "record" and len(a) >= 3:
        record(a[1], a[2], a[3] if len(a) > 3 else "")
    elif a[0] == "inject" and len(a) >= 3:
        inject(a[1], a[2])
    else:
        sys.stderr.write("usage: memory.py record <shift> <outcome> [approach] | inject <shift> <workdir>\n")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
