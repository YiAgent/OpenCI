#!/usr/bin/env python3
"""
Axiom adapter — queries logs via APL (Axiom Processing Language).

Env vars:
  AXIOM_TOKEN      API token (required)
  AXIOM_ORG_ID     Organisation ID (required for cloud)
  AXIOM_DATASET    Default dataset to query (required)
  AXIOM_APL        Custom APL query (optional — overrides built-in queries)
  OBSERVE_WINDOW   Time window like 30m, 1h, 6h (default: 30m)

Output metrics:
  log_error_rate      float ratio (error logs / total logs)
  log_error_count     int
  log_total_count     int
  log_warn_count      int
  request_p99_ms      float (if structured request logs exist with duration field)

APL contract (if AXIOM_APL set):
  The query MUST return rows with columns: name, value
  e.g. ['error_rate', 0.023], ['p99_ms', 342]
"""
import json
import os
import sys
from datetime import datetime, timezone
from urllib.request import urlopen, Request
from urllib.error import URLError, HTTPError

TOKEN   = os.environ.get("AXIOM_TOKEN", "")
ORG_ID  = os.environ.get("AXIOM_ORG_ID", "")
DATASET = os.environ.get("AXIOM_DATASET", "")
CUSTOM_APL = os.environ.get("AXIOM_APL", "")
WINDOW  = os.environ.get("OBSERVE_WINDOW", "30m")

API_BASE = "https://api.axiom.co"


def _window_minutes(window: str) -> int:
    unit = window[-1]
    val  = int(window[:-1])
    return val * {"m": 1, "h": 60, "d": 1440}.get(unit, 1)


def _query(apl: str, minutes: int) -> dict:
    url  = f"{API_BASE}/v1/datasets/_apl"
    body = {
        "apl": apl,
        "startTime": f"now-{minutes}m",
        "endTime":   "now",
    }
    data = json.dumps(body).encode()
    headers = {
        "Authorization":  f"Bearer {TOKEN}",
        "Content-Type":   "application/json",
        "Accept":         "application/json",
    }
    if ORG_ID:
        headers["X-Axiom-Org-Id"] = ORG_ID

    req = Request(f"{url}?format=legacy", data=data, headers=headers)
    try:
        with urlopen(req, timeout=30) as r:
            return json.loads(r.read())
    except HTTPError as e:
        body_text = e.read().decode(errors="replace") if hasattr(e, "read") else ""
        print(f"::warning title=Axiom::HTTP {e.code} — {body_text[:200]}", file=sys.stderr)
        return {}
    except URLError as e:
        print(f"::warning title=Axiom::{e}", file=sys.stderr)
        return {}


def log_counts(dataset: str, minutes: int) -> dict:
    apl = f"""
    ['{dataset}']
    | where _time > ago({minutes}m)
    | summarize
        total  = count(),
        errors = countif(level == "error" or level == "ERROR" or severity == "error"),
        warns  = countif(level == "warn"  or level == "WARN"  or severity == "warn")
    """
    result = _query(apl, minutes)
    totals = {}
    try:
        row = (result.get("buckets", {}).get("totals") or [{}])[0]
        totals = row.get("aggregations", {}) or row.get("data", {}) or {}
    except (IndexError, AttributeError):
        pass
    total  = int(totals.get("total",  0))
    errors = int(totals.get("errors", 0))
    warns  = int(totals.get("warns",  0))
    rate   = round(errors / total, 6) if total > 0 else 0.0
    return {"total": total, "errors": errors, "warns": warns, "rate": rate}


def request_p99(dataset: str, minutes: int) -> float:
    apl = f"""
    ['{dataset}']
    | where _time > ago({minutes}m)
    | where isnotnull(duration) or isnotnull(duration_ms) or isnotnull(latency_ms)
    | summarize p99 = percentile(
        coalesce(todouble(duration_ms), todouble(duration) * 1000, todouble(latency_ms)), 99
      )
    """
    result = _query(apl, minutes)
    try:
        row = (result.get("buckets", {}).get("totals") or [{}])[0]
        data = row.get("aggregations", {}) or row.get("data", {}) or {}
        return float(data.get("p99", 0.0))
    except (IndexError, AttributeError, TypeError, ValueError):
        return 0.0


def custom_metrics(apl: str, minutes: int) -> list[dict]:
    result = _query(apl, minutes)
    metrics = []
    try:
        for row in result.get("matches", []):
            d = row.get("data", {})
            name  = str(d.get("name", "custom"))
            value = float(d.get("value", 0))
            metrics.append({"name": name, "value": value, "unit": "custom", "tags": {}})
    except (TypeError, AttributeError):
        pass
    return metrics


def main() -> None:
    if not TOKEN or not DATASET:
        print("::error title=Axiom::AXIOM_TOKEN and AXIOM_DATASET required", file=sys.stderr)
        sys.exit(1)
    import re as _re
    if not _re.fullmatch(r"[\w\-. ]+", DATASET):
        print(f"::error title=Axiom::AXIOM_DATASET contains invalid characters: {DATASET!r}", file=sys.stderr)
        sys.exit(1)

    now_s   = int(datetime.now(timezone.utc).timestamp())
    minutes = _window_minutes(WINDOW)
    now_ts  = datetime.fromtimestamp(now_s, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    metrics = []

    if CUSTOM_APL:
        metrics.extend(custom_metrics(CUSTOM_APL, minutes))
        print(f"Axiom: custom APL returned {len(metrics)} metrics")
    else:
        counts = log_counts(DATASET, minutes)
        p99    = request_p99(DATASET, minutes)

        metrics = [
            {"name": "log_error_rate",  "value": counts["rate"],          "unit": "ratio", "tags": {"dataset": DATASET}},
            {"name": "log_error_count", "value": float(counts["errors"]),  "unit": "count", "tags": {"dataset": DATASET}},
            {"name": "log_total_count", "value": float(counts["total"]),   "unit": "count", "tags": {"dataset": DATASET}},
            {"name": "log_warn_count",  "value": float(counts["warns"]),   "unit": "count", "tags": {"dataset": DATASET}},
            {"name": "request_p99_ms",  "value": p99,                     "unit": "ms",    "tags": {"dataset": DATASET}},
        ]
        print(f"Axiom: errors={counts['errors']}/{counts['total']} rate={counts['rate']:.4f} p99={p99}ms")

    output = {
        "provider":     "axiom",
        "collected_at": now_ts,
        "window":       WINDOW,
        "metrics":      metrics,
        "raw": {"dataset": DATASET},
    }

    with open("raw-metrics.json", "w") as f:
        json.dump(output, f, indent=2)


if __name__ == "__main__":
    main()
