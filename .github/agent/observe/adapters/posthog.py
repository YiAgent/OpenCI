#!/usr/bin/env python3
"""
PostHog adapter — queries product analytics and business KPIs.

Env vars:
  POSTHOG_API_KEY     Personal API key (required)
  POSTHOG_PROJECT_ID  Numeric project ID (required)
  POSTHOG_HOST        API host (default: https://app.posthog.com)
  POSTHOG_EVENTS      Comma-sep event names to count (e.g. "purchase,signup")
  POSTHOG_FUNNEL_ID   Saved funnel insight ID to pull conversion rate (optional)
  POSTHOG_FEATURE_KEY Feature flag key to measure exposure (optional)
  OBSERVE_WINDOW      Time window like 30m, 1h, 6h (default: 30m)

Output metrics:
  event_{name}_count    int   per event in POSTHOG_EVENTS
  funnel_conversion     float percentage (if POSTHOG_FUNNEL_ID set)
  feature_flag_exposure float percentage (if POSTHOG_FEATURE_KEY set)
  error_event_count     int   (count of $exception events)
  active_users          int   (unique users in window)
"""
import json
import os
import sys
from datetime import datetime, timezone
from urllib.request import urlopen, Request
from urllib.error import URLError, HTTPError

API_KEY    = os.environ.get("POSTHOG_API_KEY", "")
PROJECT_ID = os.environ.get("POSTHOG_PROJECT_ID", "")
HOST       = os.environ.get("POSTHOG_HOST", "https://app.posthog.com").rstrip("/")
EVENTS     = [e.strip() for e in os.environ.get("POSTHOG_EVENTS", "").split(",") if e.strip()]
FUNNEL_ID  = os.environ.get("POSTHOG_FUNNEL_ID", "")
FEATURE_KEY = os.environ.get("POSTHOG_FEATURE_KEY", "")
WINDOW     = os.environ.get("OBSERVE_WINDOW", "30m")


def _window_minutes(window: str) -> int:
    unit = window[-1]
    val  = int(window[:-1])
    return val * {"m": 1, "h": 60, "d": 1440}.get(unit, 1)


def _post(path: str, body: dict) -> dict:
    url  = f"{HOST}/api/projects/{PROJECT_ID}{path}"
    data = json.dumps(body).encode()
    req  = Request(url, data=data, headers={
        "Authorization": f"Bearer {API_KEY}",
        "Content-Type": "application/json",
    })
    try:
        with urlopen(req, timeout=30) as r:
            return json.loads(r.read())
    except (HTTPError, URLError) as e:
        print(f"::warning title=PostHog::{path} → {e}", file=sys.stderr)
        return {}


def _get(path: str) -> dict:
    url = f"{HOST}/api/projects/{PROJECT_ID}{path}"
    req = Request(url, headers={"Authorization": f"Bearer {API_KEY}"})
    try:
        with urlopen(req, timeout=20) as r:
            return json.loads(r.read())
    except (HTTPError, URLError) as e:
        print(f"::warning title=PostHog::{path} → {e}", file=sys.stderr)
        return {}


def hogql_count(event: str, minutes: int) -> int:
    safe_event = event.replace("'", "\\'")
    query = {
        "query": {
            "kind": "HogQLQuery",
            "query": (
                f"SELECT count() FROM events "
                f"WHERE event = '{safe_event}' "
                f"AND timestamp >= now() - toIntervalMinute({minutes})"
            ),
        }
    }
    result = _post("/query/", query)
    try:
        return int(result["results"][0][0])
    except (KeyError, IndexError, TypeError):
        return 0


def active_users(minutes: int) -> int:
    query = {
        "query": {
            "kind": "HogQLQuery",
            "query": (
                f"SELECT count(DISTINCT distinct_id) FROM events "
                f"WHERE timestamp >= now() - toIntervalMinute({minutes})"
            ),
        }
    }
    result = _post("/query/", query)
    try:
        return int(result["results"][0][0])
    except (KeyError, IndexError, TypeError):
        return 0


def funnel_conversion(insight_id: str) -> float:
    data = _get(f"/insights/{insight_id}/")
    try:
        # PostHog funnel result: list of steps, last step has conversion_rate
        steps = data.get("result", [])
        if not steps:
            return 0.0
        last = steps[-1]
        return float(last.get("conversion_rate", 0.0))
    except (KeyError, TypeError):
        return 0.0


def feature_flag_exposure(flag_key: str, minutes: int) -> float:
    safe_key = flag_key.replace("'", "\\'")
    total_query = {
        "query": {
            "kind": "HogQLQuery",
            "query": (
                f"SELECT count() FROM events "
                f"WHERE timestamp >= now() - toIntervalMinute({minutes})"
            ),
        }
    }
    flag_query = {
        "query": {
            "kind": "HogQLQuery",
            "query": (
                f"SELECT count() FROM events "
                f"WHERE event = '$feature_flag_called' "
                f"AND JSONExtractString(properties, '$feature_flag') = '{safe_key}' "
                f"AND timestamp >= now() - toIntervalMinute({minutes})"
            ),
        }
    }
    total = _post("/query/", total_query)
    flag  = _post("/query/", flag_query)
    try:
        t = int(total["results"][0][0])
        f = int(flag["results"][0][0])
        return round(f / t * 100, 2) if t > 0 else 0.0
    except (KeyError, IndexError, TypeError):
        return 0.0


def main() -> None:
    if not API_KEY or not PROJECT_ID:
        print("::error title=PostHog::POSTHOG_API_KEY, POSTHOG_PROJECT_ID required",
              file=sys.stderr)
        sys.exit(1)

    now_s   = int(datetime.now(timezone.utc).timestamp())
    minutes = _window_minutes(WINDOW)

    metrics = []

    for event in EVENTS:
        count = hogql_count(event, minutes)
        metrics.append({
            "name":  f"event_{event}_count",
            "value": float(count),
            "unit":  "count",
            "tags":  {"event": event},
        })
        print(f"PostHog: {event}={count}")

    # Always collect error events and active users
    error_count  = hogql_count("$exception", minutes)
    user_count   = active_users(minutes)
    metrics.append({"name": "error_event_count", "value": float(error_count), "unit": "count", "tags": {}})
    metrics.append({"name": "active_users",       "value": float(user_count),  "unit": "count", "tags": {}})
    print(f"PostHog: $exception={error_count} active_users={user_count}")

    if FUNNEL_ID:
        rate = funnel_conversion(FUNNEL_ID)
        metrics.append({"name": "funnel_conversion", "value": rate, "unit": "percentage", "tags": {"funnel_id": FUNNEL_ID}})
        print(f"PostHog: funnel_conversion={rate}%")

    if FEATURE_KEY:
        exposure = feature_flag_exposure(FEATURE_KEY, minutes)
        metrics.append({"name": "feature_flag_exposure", "value": exposure, "unit": "percentage", "tags": {"flag": FEATURE_KEY}})
        print(f"PostHog: feature_flag_exposure={exposure}%")

    now_ts = datetime.fromtimestamp(now_s, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    output = {
        "provider":     "posthog",
        "collected_at": now_ts,
        "window":       WINDOW,
        "metrics":      metrics,
        "raw": {
            "project_id": PROJECT_ID,
            "host":       HOST,
        },
    }

    with open("raw-metrics.json", "w") as f:
        json.dump(output, f, indent=2)


if __name__ == "__main__":
    main()
