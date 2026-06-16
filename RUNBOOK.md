# Nightshift — Operator Runbook

The always-on supervisor: pulls **shifts** (`*.shift.json` task bundles) from `queue/pending/`,
builds each via an adapter (codex / claude / antigravity, **subscription-first**), reviews via
Handoff, and routes done / failed / requeue — under budget + circuit-breaker + rate guardrails,
with crash recovery. Spec: `../brief/docs/specs/nightshift-v2.md`.

> **Status (2026-06-16):** code complete through T1–T12 + review Pass 1. **Subscription-only**
> (`auth.fallback_api=false`). Gated for an **attended** smoke test only — see §4. Not yet cleared
> for unattended 24/7 (Pass 2 hardening + a passing smoke test required first).

---

## 1. One-time auth setup (you must do these — interactive browser logins)

Headless subscription auth is NOT wired until these exist (a live smoke proved both were missing):

```bash
# Claude Max (headless evaluator + claude adapter) — mints a long-lived token:
claude setup-token
mkdir -p ~/.config/nightshift
printf 'export CLAUDE_CODE_OAUTH_TOKEN=%s\n' "<token-from-setup-token>" > ~/.config/nightshift/secrets.env
chmod 600 ~/.config/nightshift/secrets.env          # the supervisor sources this; it's NOT in git/plist

# Codex (default builder) — `codex` on this box is a broken alias to a missing binary:
npm install -g @openai/codex      # install a REAL binary on PATH (scripts can't use shell aliases)
codex login                       # "Sign in with ChatGPT" (subscription, not API key)

# Antigravity (optional secondary) — agy is installed; OAuth on first use:
agy -p "hello"                    # completes the Google AI Ultra OAuth once
```

Verify (should NOT say "Not logged in"):
```bash
env -u ANTHROPIC_API_KEY claude -p --output-format json "say NIGHTSHIFT_OK"
```

## 2. Install / activate the daemon

```bash
mkdir -p /Users/elias/code/nightshift/nightshift/state
cp /Users/elias/code/nightshift/nightshift/ai.nightshift.supervisor.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/ai.nightshift.supervisor.plist   # RunAtLoad starts it
launchctl list | grep ai.nightshift.supervisor
```
`KeepAlive={SuccessfulExit:false}` + `ThrottleInterval:60` → crashes respawn (≥60s apart) and resume
via crash recovery; a clean stop (unload) stays stopped; an OPEN breaker keeps the daemon up-but-idle.

## 3. Operate

```bash
# queue work
cp my-feature.shift.json /Users/elias/code/nightshift/nightshift/queue/pending/

# observe
tail -f /Users/elias/code/nightshift/nightshift/state/supervisor.log
cat     /Users/elias/code/nightshift/nightshift/state/{checkpoint,budget,breaker}.json
ls      /Users/elias/code/nightshift/nightshift/queue/{pending,active,done,failed}
cat     /Users/elias/code/nightshift/nightshift/state/notifications.log

# after an OPEN breaker, once you've addressed the cause:
python3 /Users/elias/code/nightshift/nightshift/guard.py breaker-reset

# KILL SWITCH (stop always-on instantly; stays stopped):
launchctl unload ~/Library/LaunchAgents/ai.nightshift.supervisor.plist
```

## 4. Gated smoke test (attended, BEFORE enabling the daemon)

Run one real shift through the loop with every dangerous path closed, watching live:
```bash
cd /Users/elias/code/nightshift/nightshift
cp <one-tiny>.shift.json queue/pending/
caffeinate -s env \
  NS_NO_CAFFEINATE=1 \
  bash nightshift-supervisor.sh --drain-once
# watch: state/supervisor.log, state/notifications.log
```
Safe-by-config for the smoke: `auth.fallback_api=false` (no metered path), worktrees on
(per-shift isolation), `NIGHTSHIFT_NO_PUSH=1` (codex sets it — nothing pushes), review gate on.
Confirm: builds on subscription (no metered API call), review verdict routes correctly, worktree
cleaned up, no unexpected commits/pushes to the graveyard repo. Only after this passes — and Pass 2
lands — consider `launchctl load` for unattended runs.

## 5. Rollback

```bash
launchctl unload ~/Library/LaunchAgents/ai.nightshift.supervisor.plist   # stop
# repos are renamed copies of the originals + tagged pre-nightshift-rename:
git -C /Users/elias/code/nightshift/<repo> reset --hard pre-nightshift-rename   # if needed
```

## 6. Known gaps (Pass 2 — do before unattended 24/7)

- **Adapter signal emission** (the last critical, partial): adapters don't yet classify CLI output
  into `subscription_exhausted` / `permission_denial`, nor emit `no_progress` on a zero-progress build,
  so those breaker branches are dormant on the live path (the error-count breaker IS live). `guard.py`
  already handles the signals once emitted.
- Real metered-fallback wiring (so `fallback_api=true` + the $20/day / $5/run ledger become live).
- `nightshift/*` branch pruning/retention; `claude.sh` `env -i` sandboxing; Gemini-reviewer rewire
  (+ key-in-URL leak in `handoff` repo); graveyard `PIPESTATUS` codex-rc capture; explicit per-shift
  build-target repo (today it defaults to the graveyard repo with push disabled).
