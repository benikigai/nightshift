# Nightshift

Controlled agent work loops for GitHub tasks.

[Product page](https://nightshift.kogenlabs.dev) |
[Original AgentForge demo](https://agent-forge-rho-ten.vercel.app)

Nightshift is an agentic development supervisor. It turns a scoped task into a
bounded loop:

```txt
spec -> build -> gate -> evaluate -> retry or commit -> audit
```

The key idea is simple: the coding agent writes code, but the harness owns
authority. The harness picks one task, runs the builder, checks the result,
asks a separate evaluator to score it, records metrics, and only then commits
or retries.

## Why this exists

Most agent coding runs fail in boring ways:

- the task is too broad
- the agent grades its own work
- failed attempts leave no useful trail
- cost and retry behavior are invisible
- success means "the agent said it worked"

Nightshift makes the loop explicit. A builder can propose work, but it does not
decide whether the work ships.

## What this repo contains

This repo is the original **AgentForge** proof run, now positioned as the public
Nightshift specimen. It contains:

- a reusable build loop (`ralph-loop.sh`)
- a structured feature queue (`feature_list.json`)
- a separate evaluator contract (`evaluate.py`)
- a mutation guard for feature specs (`json_guard.py`)
- a metrics writer (`metrics_writer.py`)
- a generated Next.js dashboard that visualizes the run (`src/`)
- the run data behind the dashboard (`public/metrics.json`)

The dashboard is not just a demo page. It is the receipt for the loop that built
it.

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

The run produced a full dashboard with routes for overview, timeline, quality,
features, token spend, git history, and architecture. Each chart reads from the
same metrics file the loop wrote while building.

## Architecture

```txt
Nightshift
  supervisor for queued GitHub work

Graveyard
  one-task-at-a-time build loop

Handoff
  review layer: approve, request changes, requeue, or escalate

Guard
  budget, rate-limit, circuit-breaker, permission, and audit controls
```

This public repo is the Graveyard/AgentForge proof specimen. The broader
Nightshift system adds queue supervision, GitHub comment triggers, check-run
updates, Handoff review, and operational guardrails.

## Loop mechanics

1. Read the feature queue.
2. Select the first pending feature.
3. Run the builder on exactly that feature.
4. Run build/test gates.
5. Send the diff to a separate evaluator.
6. If score is below threshold, write targeted feedback and retry.
7. If score passes, mark the feature, write metrics, commit, and continue.
8. If attempts are exhausted, skip or escalate instead of pretending it passed.

The builder is intentionally not allowed to mark its own feature complete.
`json_guard.py` protects the feature list so the loop can only advance through
controlled mutations.

## Why the evaluator matters

Self-review is the weak point in many agent workflows. This repo uses a separate
model/context to score the diff against the feature spec.

The scoring contract weights:

- completeness
- visual/code quality
- absence of placeholders
- build/test gate behavior

When a feature fails, feedback must name the file and the specific fix. Vague
feedback is rejected by design.

## Run locally

```sh
npm install
npm run dev
```

Open:

```txt
http://localhost:3000
```

Build and test:

```sh
npm run build
npm test
```

Run the loop:

```sh
./ralph-loop.sh
```

Run the loop against another project:

```sh
./ralph-loop.sh \
  --features /path/to/features.json \
  --prompt /path/to/PROMPT_build.md \
  --project-dir /path/to/project
```

## Files to inspect first

- `ralph-loop.sh` - outer loop, retry loop, commit authority, push cadence
- `PROMPT_build.md` - builder instructions
- `EVALUATOR.md` - evaluator scoring contract
- `evaluate.py` - evaluator bridge
- `json_guard.py` - feature-list mutation guard
- `metrics_writer.py` - metrics accumulator
- `public/metrics.json` - recorded proof-run data
- `src/app/architecture/page.tsx` - visual explanation of the system

## What to copy

The useful pattern is not the dashboard UI. It is the loop contract:

- one scoped task at a time
- builder and evaluator separated
- objective gates before scoring
- retries based on specific feedback
- metrics written during the run
- git commits only after passing work
- explicit skip/escalation path

That pattern can be moved into other agentic coding systems, data-quality loops,
documentation loops, or ops workflows.

## What this is not

This repo is not the final hosted Nightshift product. It is the original public
specimen: a working loop, a proof dashboard, and the evidence trail from the run
that created it.

The product direction is here:

```txt
https://nightshift.kogenlabs.dev
```

## Why star it

Star this repo if you are interested in practical agentic engineering systems
that care about:

- bounded autonomy
- evaluator backpressure
- visible cost and retry behavior
- git-backed audit trails
- agent work that can stop safely

The bet: agent workflows get more useful when the harness is stricter than the
agent.
