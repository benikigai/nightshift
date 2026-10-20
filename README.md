# Nightshift

Controlled agent harness for lights-out software work.

> **Status: Reference (public specimen).** Last meaningful update: June 2026 (repositioning as Nightshift); loop code last changed April 2026. The proof run itself is frozen. Active Nightshift development happens in the private supervisor repo.

Nightshift runs persistent Ralph Loops over scoped tasks: build, gate,
evaluate, retry, commit, audit.

[Product page](https://nightshift.kogenlabs.dev) |
[Original AgentForge demo](https://agent-forge-rho-ten.vercel.app)

```txt
spec -> build -> gate -> evaluate -> retry or commit -> audit
```

The coding agent writes code, but the harness owns authority. The harness picks
one task, runs the builder, checks the result, asks a separate evaluator to
score it, records metrics, and only then commits or retries.

## What this repo is

This is the original **AgentForge** proof run (formerly `benikigai/AgentForge`),
kept public as the Nightshift specimen. It contains:

- a reusable build loop (`ralph-loop.sh`), the "Graveyard" stage of Nightshift
- a structured feature queue (`feature_list.json`)
- a separate evaluator contract (`EVALUATOR.md`, `evaluate.py`)
- a mutation guard for feature specs (`json_guard.py`)
- a metrics writer (`metrics_writer.py`, `backfill_metrics.py`)
- a generated Next.js dashboard that visualizes the run (`src/`)
- the run data behind the dashboard (`public/metrics.json`)

The dashboard is the receipt for the loop that built it.

## How it fits with related repos

| Repo | Role | Former name |
| --- | --- | --- |
| `nightshift-brief` | Planning: `/spec`, `/yolo`, `/forge` Claude Code skills | SpecForge |
| **`nightshift`** (this repo) | Build loop + proof dashboard | AgentForge |
| `nightshift-handoff` | Review: multi-model `/review`, `/triage`, `/pr` | ReviewForge |
| `nightshift-private` (private) | Supervisor: queue, dispatcher, guardrails, GitHub App, product site | - |

Old `SpecForge` / `AgentForge` / `ReviewForge` URLs redirect to the renamed repos.

## Proof run

| Metric | Result |
| --- | ---: |
| Features | 29/30 passed |
| Skipped features | 1 |
| Evaluated attempts | 41 |
| Average passing score | 9.69/10 |
| Tokens | 109,270 |
| Cost | about $0.95 |
| Elapsed time | 76 minutes |

Routes: overview, timeline, quality, features, token spend, git history, and
architecture. Every chart reads from the metrics file the loop wrote while building.

## Loop mechanics

1. Read the feature queue.
2. Select the first pending feature.
3. Run the builder on exactly that feature.
4. Run build/test gates.
5. Send the diff to a separate evaluator.
6. If the score is below threshold, write targeted feedback and retry.
7. If the score passes, mark the feature, write metrics, commit, and continue.
8. If attempts are exhausted, skip or escalate instead of pretending it passed.

The builder cannot mark its own feature complete. `json_guard.py` protects the
feature list so the loop only advances through controlled mutations. Evaluator
feedback must name the file and the specific fix; vague feedback is rejected.

## Layout

```txt
ralph-loop.sh        outer loop, retry loop, commit authority, push cadence
kickoff.sh, init.sh  run bootstrap
PROMPT_build.md      builder instructions
PROMPT_plan.md       planning prompt
EVALUATOR.md         evaluator scoring contract
evaluate.py          evaluator bridge
json_guard.py        feature-list mutation guard
metrics_writer.py    metrics accumulator
feature_list.json    the 30-feature queue from the proof run
public/metrics.json  recorded proof-run data
src/                 Next.js 15 dashboard (app router, Recharts)
scripts/build.mjs    build wrapper
```

## Run

Dashboard:

```sh
npm install
npm run dev        # http://localhost:3000
npm run build
npm test           # vitest
```

Loop (requires the `codex` CLI for the builder and an evaluator model credential):

```sh
./ralph-loop.sh
./ralph-loop.sh \
  --features path/to/features.json \
  --prompt path/to/PROMPT_build.md \
  --project-dir path/to/project
```

## Config and secrets

- Model credentials come from the shell environment (`OPENAI_API_KEY` /
  Codex login for the builder, `ANTHROPIC_API_KEY` for the evaluator).
- `.env` and `.env.local` are gitignored. Never commit keys.
- The dashboard itself needs no secrets; it only reads `public/metrics.json`.

## Maintenance notes

- Treat `public/metrics.json`, `feature_list.json`, and the commit history as
  frozen evidence. Do not rewrite them.
- `.ralph-pid` and `claude-progress.txt` are run leftovers and can be removed
  and gitignored.
- PR #1 (docs-enforcement CI, April 2026) is still open; merge or close it.
- New harness features belong in the private supervisor repo, not here.

## License

No license file yet. Add one (MIT matches the sibling repos) if reuse is intended.
