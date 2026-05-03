#!/usr/bin/env python3
"""
Sentry adapter — outputs raw-metrics.json with release health and error data.

Env vars:
  SENTRY_TOKEN      Bearer token (required)
  SENTRY_ORG        Organization slug (required)
  SENTRY_PROJECT    Project slug (required)
  SENTRY_ENV        Environment name (default: production)
  SENTRY_RELEASE    Release version to check health for (optional)
  OBSERVE_WINDOW    Time window like 30m, 1h, 6h (default: 30m)

Output metrics:
  error_rate              float (errors / total events)
  crash_free_rate         float percentage (0-100)
  new_issues_count        int   (issues created since deploy start)
  p95_transaction_ms      float (p95 web transaction duration)
  apdex                   float (0-1, 1 = perfect)
"""
import json
import os
import sys
from datetime import datetime, timezone
from urllib.parse import urlencode
from urllib.request import urlopen, Request
from urllib.error import URLError, HTTPError

TOKEN   = os.environ.get("SENTRY_TOKEN", "")
ORG     = os.environ.get("SENTRY_ORG", "")
PROJECT = os.environ.get("SENTRY_PROJECT", "")
ENV     = os.environ.get("SENTRY_ENV", "production")
RELEASE = os.environ.get("SENTRY_RELEASE", "")
WINDOW  = os.environ.get("OBSERVE_WINDOW", "30m")

BASE = "https://sentry.io/api/0"


def _window_seconds(window: str) -> int:
    unit = window[-1]
    val  = int(window[:-1])
    return val * {"m": 60, "h": 3600, "d": 86400}.get(unit, 60)


def _ts(epoch: int) -> str:
    return datetime.fromtimestamp(epoch, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _get(path: str, params: dict | None = None) -> dict | list:
    url = f"{BASE}{path}"
    if params:
        url = f"{url}?{urlencode(params)}"
    req = Request(url, headers={"Authorization": f"Bearer {TOKEN}"})
    try:
        with urlopen(req, timeout=20) as r:
            return json.loads(r.read())
    except (HTTPError, URLError) as e:
        print(f"::warning title=Sentry::{path} → {e}", file=sys.stderr)
        return {}


def error_rate(now_s: int, window_s: int) -> float:
    start = _ts(now_s - window_s)
    end   = _ts(now_s)
    total_data  = _get(f"/organizations/{ORG}/stats_v2/",
                       {"field": "sum(quantity)", "groupBy": "outcome",
                        "project": PROJECT, "environment": ENV,
                        "start": start, "end": end, "interval": "1m"})
    error_data  = _get(f"/organizations/{ORG}/stats_v2/",
                       {"field": "sum(quantity)", "groupBy": "outcome",
                        "category": "error",
                        "project": PROJECT, "environment": ENV,
                        "start": start, "end": end, "interval": "1m"})

    def _sum(data):
        groups = data.get("groups", []) if isinstance(data, dict) else []
        return sum(g.get("totals", {}).get("sum(quantity)", 0) for g in groups)

    total  = _sum(total_data)
    errors = _sum(error_data)
    return round(errors / total, 6) if total > 0 else 0.0


def crash_free_rate(now_s: int, window_s: int) -> float:
    start = _ts(now_s - window_s)
    end   = _ts(now_s)
    params = {
        "project": PROJECT, "environment": ENV,
        "start": start, "end": end,
        "field": "sum(session)", "groupBy": "session.status",
        "interval": "1h",
    }
    data = _get(f"/organizations/{ORG}/sessions/", params)
    groups = data.get("groups", []) if isinstance(data, dict) else []
    total   = sum(g.get("totals", {}).get("sum(session)", 0) for g in groups)
    crashed = sum(
        g.get("totals", {}).get("sum(session)", 0)
        for g in groups
        if g.get("by", {}).get("session.status") == "crashed"
    )
    if total == 0:
        return 100.0
    return round((total - crashed) / total * 100, 2)


def new_issues(now_s: int, window_s: int) -> int:
    start_dt = datetime.fromtimestamp(now_s - window_s, tz=timezone.utc)
    first_seen = start_dt.strftime("%Y-%m-%dT%H:%M:%SZ")
    data = _get(f"/projects/{ORG}/{PROJECT}/issues/", {
        "environment": ENV,
        "firstSeen": f">{first_seen}",
        "limit": "100",
        "query": "is:unresolved",
    })
    return len(data) if isinstance(data, list) else 0


def performance(now_s: int, window_s: int) -> dict:
    start = _ts(now_s - window_s)
    end   = _ts(now_s)
    data = _get(f"/organizations/{ORG}/events/", {
        "project": PROJECT, "environment": ENV,
        "field": "p95(transaction.duration),apdex(300),count()",
        "start": start, "end": end,
        "dataset": "metrics",
    })
    if not isinstance(data, dict):
        return {"p95_ms": 0.0, "apdex": 1.0}
    row = (data.get("data") or [{}])[0]
    return {
        "p95_ms": float(row.get("p95(transaction.duration)", 0)),
        "apdex":  float(row.get("apdex(300)", 1.0)),
    }


def main() -> None:
    if not TOKEN or not ORG or not PROJECT:
        print("::error title=Sentry::SENTRY_TOKEN, SENTRY_ORG, SENTRY_PROJECT required",
              file=sys.stderr)
        sys.exit(1)

    now_s    = int(datetime.now(timezone.utc).timestamp())
    window_s = _window_seconds(WINDOW)

    err_rate   = error_rate(now_s, window_s)
    cfr        = crash_free_rate(now_s, window_s)
    issue_cnt  = new_issues(now_s, window_s)
    perf       = performance(now_s, window_s)

    output = {
        "provider": "sentry",
        "collected_at": _ts(now_s),
        "window": WINDOW,
        "metrics": [
            {"name": "error_rate",          "value": err_rate,          "unit": "ratio",      "tags": {"env": ENV}},
            {"name": "crash_free_rate",     "value": cfr,               "unit": "percentage", "tags": {"env": ENV}},
            {"name": "new_issues_count",    "value": float(issue_cnt),  "unit": "count",      "tags": {"env": ENV}},
            {"name": "p95_transaction_ms",  "value": perf["p95_ms"],    "unit": "ms",         "tags": {"env": ENV}},
            {"name": "apdex",               "value": perf["apdex"],     "unit": "score",      "tags": {"env": ENV}},
        ],
        "raw": {
            "org":     ORG,
            "project": PROJECT,
            "release": RELEASE,
        },
    }

    with open("raw-metrics.json", "w") as f:
        json.dump(output, f, indent=2)
    print(f"Sentry: error_rate={err_rate:.4f} cfr={cfr}% new_issues={issue_cnt} apdex={perf['apdex']}")


if __name__ == "__main__":
    main()
