#!/usr/bin/env python3
"""
Datadog adapter — queries infrastructure and APM metrics via Metrics API v1.

Env vars:
  DD_API_KEY       Datadog API key (required)
  DD_APP_KEY       Datadog application key (required)
  DD_SITE          Datadog site (default: datadoghq.com)
  DD_QUERIES       JSON array of {name, query} objects (optional)
                   e.g. '[{"name":"error_rate","query":"avg:trace.web.request.errors{env:production}"}]'
  DD_SERVICE       Service tag filter (default: "")
  DD_ENV           Environment tag (default: production)
  OBSERVE_WINDOW   Time window like 30m, 1h, 6h (default: 30m)

Built-in queries (run if DD_QUERIES not set):
  cpu_usage       avg:system.cpu.user{*}
  memory_usage    avg:system.mem.pct_usable{*} (inverted to used %)
  error_rate      avg:trace.web.request.errors{*}
  p99_latency_ms  avg:trace.web.request.duration.by.resource_service.99p{*} * 1000

Output metrics: one metric per query, unit inferred from name suffix.
"""
import json
import os
import sys
from datetime import datetime, timezone
from urllib.request import urlopen, Request
from urllib.error import URLError, HTTPError

API_KEY  = os.environ.get("DD_API_KEY", "")
APP_KEY  = os.environ.get("DD_APP_KEY", "")
SITE     = os.environ.get("DD_SITE", "datadoghq.com")
SERVICE  = os.environ.get("DD_SERVICE", "")
ENV      = os.environ.get("DD_ENV", "production")
WINDOW   = os.environ.get("OBSERVE_WINDOW", "30m")
CUSTOM_QUERIES = os.environ.get("DD_QUERIES", "")

BASE = f"https://api.{SITE}"

BUILT_IN = [
    {
        "name":  "cpu_usage",
        "query": "avg:system.cpu.user{{*}}",
        "unit":  "percentage",
    },
    {
        "name":  "memory_usage",
        "query": "100 - avg:system.mem.pct_usable{{*}} * 100",
        "unit":  "percentage",
    },
    {
        "name":  "error_rate",
        "query": "avg:trace.web.request.errors{{env:{env}}}",
        "unit":  "ratio",
    },
    {
        "name":  "p99_latency_ms",
        "query": "avg:trace.web.request.duration.by.resource_service.99p{{env:{env}}} * 1000",
        "unit":  "ms",
    },
    {
        "name":  "requests_per_second",
        "query": "sum:trace.web.request.hits{{env:{env}}}.as_rate()",
        "unit":  "per_second",
    },
]


def _window_seconds(window: str) -> int:
    unit = window[-1]
    val  = int(window[:-1])
    return val * {"m": 60, "h": 3600, "d": 86400}.get(unit, 60)


def _query_metric(query: str, now_s: int, window_s: int) -> float:
    params = f"query={query}&from={now_s - window_s}&to={now_s}"
    url = f"{BASE}/api/v1/query?{params}"
    req = Request(url, headers={
        "DD-API-KEY":         API_KEY,
        "DD-APPLICATION-KEY": APP_KEY,
    })
    try:
        with urlopen(req, timeout=20) as r:
            data = json.loads(r.read())
    except (HTTPError, URLError) as e:
        print(f"::warning title=Datadog::{query[:60]} → {e}", file=sys.stderr)
        return 0.0

    series = data.get("series", [])
    if not series:
        return 0.0
    pointlist = series[0].get("pointlist", [])
    if not pointlist:
        return 0.0
    # Average across all points in the window
    values = [p[1] for p in pointlist if p[1] is not None]
    return round(sum(values) / len(values), 4) if values else 0.0


def _infer_unit(name: str) -> str:
    if name.endswith("_ms"):
        return "ms"
    if name.endswith("_rate") or name.endswith("_ratio"):
        return "ratio"
    if name.endswith("_pct") or name.endswith("_usage") or name.endswith("_percent"):
        return "percentage"
    if name.endswith("_per_second") or name.endswith("_rps"):
        return "per_second"
    return "count"


def main() -> None:
    if not API_KEY or not APP_KEY:
        print("::error title=Datadog::DD_API_KEY and DD_APP_KEY required", file=sys.stderr)
        sys.exit(1)

    now_s    = int(datetime.now(timezone.utc).timestamp())
    window_s = _window_seconds(WINDOW)
    now_ts   = datetime.fromtimestamp(now_s, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    # Resolve query list
    if CUSTOM_QUERIES:
        try:
            queries = json.loads(CUSTOM_QUERIES)
        except json.JSONDecodeError as e:
            print(f"::error title=Datadog::DD_QUERIES parse error — {e}", file=sys.stderr)
            sys.exit(1)
    else:
        tag_filter = f"env:{ENV}" + (f",service:{SERVICE}" if SERVICE else "")
        queries = []
        for q in BUILT_IN:
            resolved = q["query"].format(env=ENV, service=SERVICE, tag=tag_filter)
            queries.append({"name": q["name"], "query": resolved, "unit": q.get("unit")})

    metrics = []
    for q in queries:
        value = _query_metric(q["query"], now_s, window_s)
        unit  = q.get("unit") or _infer_unit(q["name"])
        metrics.append({
            "name":  q["name"],
            "value": value,
            "unit":  unit,
            "tags":  {"env": ENV, **({"service": SERVICE} if SERVICE else {})},
        })
        print(f"Datadog: {q['name']}={value} ({unit})")

    output = {
        "provider":     "datadog",
        "collected_at": now_ts,
        "window":       WINDOW,
        "metrics":      metrics,
        "raw": {"site": SITE, "env": ENV, "service": SERVICE},
    }

    with open("raw-metrics.json", "w") as f:
        json.dump(output, f, indent=2)


if __name__ == "__main__":
    main()
