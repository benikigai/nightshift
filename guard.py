#!/usr/bin/env python3
"""nightshift/guard.py — budget ledger, circuit breaker, rate limiter, notifications.

Fail-safe by design (Pass-1 review remediation):
  - state writes are atomic (temp + os.replace) so a crash can't corrupt the ledger
  - a CORRUPT state file fails SAFE (breaker treated OPEN, budget treated exceeded)
  - an unreadable config fails the budget cap CLOSED (cap defaults to 0, not infinity)
  - the breaker emits its HALT notification once, on the CLOSED->OPEN edge (no alert-spam)

State in $NIGHTSHIFT_STATE (default nightshift/state/): budget.json, breaker.json, rate.json,
notifications.log. Subcommands: see main(). Exit 0 = "yes/true" for the *-exceeded / breaker-open checks.
"""
import datetime
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG = os.environ.get("NIGHTSHIFT_CONFIG", os.path.join(HERE, "nightshift.config.json"))
STATE = os.environ.get("NIGHTSHIFT_STATE", os.path.join(HERE, "state"))

_CONFIG_OK = True


def cfg():
    global _CONFIG_OK
    try:
        return json.load(open(CONFIG))
    except Exception:
        _CONFIG_OK = False
        return {}


def _load(name, default, fail_safe=None):
    """Missing file -> default (clean start). Corrupt file -> fail_safe if given, else default."""
    p = os.path.join(STATE, name)
    if not os.path.exists(p):
        return dict(default)
    try:
        return json.load(open(p))
    except Exception:
        return dict(fail_safe) if fail_safe is not None else dict(default)


def _save(name, data):
    os.makedirs(STATE, exist_ok=True)
    p = os.path.join(STATE, name)
    tmp = p + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, p)  # atomic on POSIX


def _today():
    return datetime.date.today().isoformat()


def _hour():
    return datetime.datetime.now().strftime("%Y-%m-%dT%H")


# --- budget ---
def budget_record(usd):
    b = _load("budget.json", {"date": _today(), "daily_usd_spent": 0.0})
    if b.get("date") != _today():
        b = {"date": _today(), "daily_usd_spent": 0.0}
    b["daily_usd_spent"] = round(float(b.get("daily_usd_spent", 0.0)) + float(usd), 6)
    _save("budget.json", b)
    print(b["daily_usd_spent"])


def _spent_today():
    # corrupt ledger -> treat as infinite spend (fail closed)
    b = _load("budget.json", {"date": _today(), "daily_usd_spent": 0.0},
              fail_safe={"date": _today(), "daily_usd_spent": float("inf")})
    return float(b.get("daily_usd_spent", 0.0)) if b.get("date") == _today() else 0.0


def budget_status():
    cap = float(cfg().get("budgets", {}).get("daily_usd", 0))
    spent = _spent_today()
    print(json.dumps({"date": _today(), "spent": spent, "cap": cap,
                      "remaining": round(cap - spent, 6), "config_ok": _CONFIG_OK}))


def budget_exceeded():
    # cap defaults to 0 so an unreadable config fails CLOSED (halts spend), never open-to-infinity
    cap = float(cfg().get("budgets", {}).get("daily_usd", 0))
    sys.exit(0 if _spent_today() >= cap else 1)


# --- circuit breaker ---
def _breaker():
    return _load("breaker.json",
                 {"state": "CLOSED", "no_progress": 0, "errors": {}, "reason": "", "notified": False},
                 fail_safe={"state": "OPEN", "no_progress": 0, "errors": {},
                            "reason": "corrupt breaker state — failing safe", "notified": False})


def breaker_record(outcome, sig=""):
    cb = cfg().get("circuit_breaker", {})
    b = _breaker()
    was_open = b.get("state") == "OPEN"
    if outcome == "progress":
        b["no_progress"] = 0
        b["errors"] = {}
    elif outcome == "no_progress":
        b["no_progress"] = b.get("no_progress", 0) + 1
        if b["no_progress"] >= int(cb.get("no_progress", 3)):
            b["state"] = "OPEN"
            b["reason"] = "%d consecutive no-progress shifts" % b["no_progress"]
    elif outcome == "error":
        errs = b.get("errors", {})
        errs[sig] = errs.get(sig, 0) + 1
        b["errors"] = errs
        if errs[sig] >= int(cb.get("repeated_errors", 5)):
            b["state"] = "OPEN"
            b["reason"] = "%dx repeated error: %s" % (errs[sig], sig)
    elif outcome == "permission_denial":
        b["state"] = "OPEN"
        b["reason"] = "permission denial"
    elif outcome == "subscription_exhausted":
        if cfg().get("auth", {}).get("fallback_api", False):
            b["reason"] = "subscription exhausted -> metered fallback (bounded by budget)"
        else:
            b["state"] = "OPEN"
            b["reason"] = "subscription pool exhausted (no metered fallback)"
    now_open = b.get("state") == "OPEN"
    if now_open and not was_open:
        b["notified"] = True
        notify("Nightshift breaker OPEN — dispatch halted", b.get("reason", ""))
    elif not now_open:
        b["notified"] = False
    _save("breaker.json", b)
    print(json.dumps(b))


def breaker_open():
    sys.exit(0 if _breaker().get("state") == "OPEN" else 1)


def breaker_reason():
    print(_breaker().get("reason", ""))


def breaker_reset():
    _save("breaker.json", {"state": "CLOSED", "no_progress": 0, "errors": {}, "reason": "", "notified": False})
    print("CLOSED")


# --- rate limiter ---
def rate_record():
    r = _load("rate.json", {"hour": _hour(), "calls": 0})
    if r.get("hour") != _hour():
        r = {"hour": _hour(), "calls": 0}
    r["calls"] = r.get("calls", 0) + 1
    _save("rate.json", r)
    print(r["calls"])


def rate_exceeded():
    cap = int(cfg().get("rate", {}).get("hourly_call_cap", 60))
    r = _load("rate.json", {"hour": _hour(), "calls": 0})
    calls = r.get("calls", 0) if r.get("hour") == _hour() else 0
    sys.exit(0 if calls >= cap else 1)


# --- telemetry ingest (post-shift accounting) ---
def ingest_telemetry(path, rc):
    try:
        t = json.load(open(path))
    except Exception:
        t = {}
    auth = t.get("auth_path", "subscription")
    cost = float(t.get("cost_usd", 0) or 0)
    signal = t.get("signal", "")
    status = t.get("status", "ok" if str(rc) == "0" else "failed")
    if auth == "fallback" and cost > 0:
        budget_record(cost)
        per_run = float(cfg().get("budgets", {}).get("per_run_usd", 0) or 0)
        if per_run and cost > per_run:
            notify("Nightshift per-run budget exceeded", "shift cost $%.4f > cap $%.4f" % (cost, per_run))
            breaker_record("error", "per_run_budget")
            return
    if signal in ("permission_denial", "subscription_exhausted", "no_progress"):
        breaker_record(signal)
    elif status == "ok":
        breaker_record("progress")
    else:
        breaker_record("error", t.get("error_sig", "build_failed"))


# --- notify ---
def notify(title, message):
    os.makedirs(STATE, exist_ok=True)
    stamp = datetime.datetime.now().isoformat()
    with open(os.path.join(STATE, "notifications.log"), "a") as f:
        f.write("%s | %s | %s\n" % (stamp, title, message))
    cmd = os.environ.get("NIGHTSHIFT_NOTIFY_CMD")
    if cmd:
        import subprocess
        try:
            subprocess.run([cmd, title, message], timeout=20)
        except Exception:
            pass
    print("notified")


def main():
    a = sys.argv[1:]
    if not a:
        sys.stderr.write(__doc__)
        return 2
    cmd, rest = a[0], a[1:]
    table = {
        "budget-record": lambda: budget_record(rest[0]),
        "budget-status": budget_status,
        "budget-exceeded": budget_exceeded,
        "breaker-record": lambda: breaker_record(rest[0], rest[1] if len(rest) > 1 else ""),
        "breaker-open": breaker_open,
        "breaker-reason": breaker_reason,
        "breaker-reset": breaker_reset,
        "rate-record": rate_record,
        "rate-exceeded": rate_exceeded,
        "ingest-telemetry": lambda: ingest_telemetry(rest[0], rest[1] if len(rest) > 1 else "0"),
        "notify": lambda: notify(rest[0] if rest else "", rest[1] if len(rest) > 1 else ""),
    }
    fn = table.get(cmd)
    if fn is None:
        sys.stderr.write("unknown subcommand: %s\n" % cmd)
        return 2
    fn()
    return 0


if __name__ == "__main__":
    sys.exit(main())
