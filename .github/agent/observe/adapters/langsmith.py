#!/usr/bin/env python3
"""
LangSmith adapter — monitors LLM application runs, latency, cost, and evals.

Env vars:
  LANGSMITH_API_KEY    API key (required)
  LANGSMITH_PROJECT    Project name (required)
  LANGCHAIN_ENDPOINT   API base (default: https://api.smith.langchain.com)
  LS_RUN_TYPE          Filter by run type: llm|chain|tool|all (default: all)
  LS_EVAL_DATASET      Dataset name to pull latest eval results (optional)
  OBSERVE_WINDOW       Time window like 30m, 1h, 6h (default: 30m)

Output metrics:
  run_count             int   (total runs in window)
  run_error_rate        float ratio (error runs / total runs)
  run_p50_latency_ms    float (p50 run duration)
  run_p99_latency_ms    float (p99 run duration)
  total_tokens          int   (prompt + completion tokens)
  total_cost_usd        float (estimated cost if available)
  eval_score            float (latest eval score 0-1, if LS_EVAL_DATASET set)
  feedback_score        float (average human feedback score, if available)
"""
import json
import os
import sys
import statistics
from datetime import datetime, timezone, timedelta
from urllib.request import urlopen, Request
from urllib.error import URLError, HTTPError
from urllib.parse import urlencode

API_KEY  = os.environ.get("LANGSMITH_API_KEY", "")
PROJECT  = os.environ.get("LANGSMITH_PROJECT", "")
BASE     = os.environ.get("LANGCHAIN_ENDPOINT", "https://api.smith.langchain.com").rstrip("/")
RUN_TYPE = os.environ.get("LS_RUN_TYPE", "all")
EVAL_DS  = os.environ.get("LS_EVAL_DATASET", "")
WINDOW   = os.environ.get("OBSERVE_WINDOW", "30m")


def _window_minutes(window: str) -> int:
    unit = window[-1]
    val  = int(window[:-1])
    return val * {"m": 1, "h": 60, "d": 1440}.get(unit, 1)


def _get(path: str, params: dict | None = None) -> dict | list:
    url = f"{BASE}{path}"
    if params:
        url = f"{url}?{urlencode(params)}"
    req = Request(url, headers={"x-api-key": API_KEY})
    try:
        with urlopen(req, timeout=30) as r:
            return json.loads(r.read())
    except (HTTPError, URLError) as e:
        print(f"::warning title=LangSmith::{path} → {e}", file=sys.stderr)
        return {}


def fetch_runs(start_iso: str, end_iso: str) -> list[dict]:
    params: dict = {
        "project_name": PROJECT,
        "start_time":   start_iso,
        "end_time":     end_iso,
        "limit":        500,
        "select":       "id,status,latency,prompt_tokens,completion_tokens,total_cost,run_type",
    }
    if RUN_TYPE != "all":
        params["run_type"] = RUN_TYPE

    data = _get("/runs", params)
    if isinstance(data, list):
        return data
    return data.get("runs", []) if isinstance(data, dict) else []


def run_stats(runs: list[dict]) -> dict:
    total   = len(runs)
    errors  = sum(1 for r in runs if r.get("status") in {"error", "failed"})
    latencies = [
        r["latency"] * 1000  # LangSmith returns seconds
        for r in runs
        if r.get("latency") is not None and r["latency"] > 0
    ]
    tokens = sum(
        (r.get("prompt_tokens") or 0) + (r.get("completion_tokens") or 0)
        for r in runs
    )
    cost = sum(r.get("total_cost") or 0.0 for r in runs)

    p50 = statistics.median(latencies) if latencies else 0.0
    p99 = statistics.quantiles(latencies, n=100)[98] if len(latencies) >= 100 else (max(latencies) if latencies else 0.0)

    return {
        "count":     total,
        "errors":    errors,
        "error_rate": round(errors / total, 6) if total > 0 else 0.0,
        "p50_ms":    round(p50, 1),
        "p99_ms":    round(p99, 1),
        "tokens":    tokens,
        "cost_usd":  round(cost, 6),
    }


def latest_eval_score(dataset: str) -> float:
    data = _get("/datasets", {"name": dataset})
    datasets = data if isinstance(data, list) else data.get("datasets", [])
    if not datasets:
        return -1.0
    dataset_id = datasets[0].get("id")
    if not dataset_id:
        return -1.0

    results = _get(f"/datasets/{dataset_id}/comparative_experiments")
    experiments = results if isinstance(results, list) else results.get("experiments", [])
    if not experiments:
        return -1.0

    latest = sorted(experiments, key=lambda x: x.get("start_time", ""), reverse=True)[0]
    scores = [
        float(s.get("score", 0))
        for s in latest.get("feedback_stats", {}).values()
        if s.get("score") is not None
    ]
    return round(sum(scores) / len(scores), 4) if scores else -1.0


def feedback_score(start_iso: str, end_iso: str) -> float:
    data = _get("/feedback", {
        "project_name": PROJECT,
        "start_time":   start_iso,
        "end_time":     end_iso,
        "limit":        500,
    })
    items = data if isinstance(data, list) else data.get("feedback", [])
    scores = [float(f["score"]) for f in items if f.get("score") is not None]
    return round(sum(scores) / len(scores), 4) if scores else -1.0


def main() -> None:
    if not API_KEY or not PROJECT:
        print("::error title=LangSmith::LANGSMITH_API_KEY and LANGSMITH_PROJECT required",
              file=sys.stderr)
        sys.exit(1)

    now_utc  = datetime.now(timezone.utc)
    minutes  = _window_minutes(WINDOW)
    start    = now_utc - timedelta(minutes=minutes)
    start_iso = start.strftime("%Y-%m-%dT%H:%M:%SZ")
    end_iso   = now_utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    now_ts    = end_iso

    runs  = fetch_runs(start_iso, end_iso)
    stats = run_stats(runs)

    print(
        f"LangSmith: runs={stats['count']} error_rate={stats['error_rate']:.4f} "
        f"p50={stats['p50_ms']}ms p99={stats['p99_ms']}ms "
        f"tokens={stats['tokens']} cost=${stats['cost_usd']:.4f}"
    )

    metrics = [
        {"name": "run_count",          "value": float(stats["count"]),      "unit": "count",   "tags": {"project": PROJECT}},
        {"name": "run_error_rate",     "value": stats["error_rate"],        "unit": "ratio",   "tags": {"project": PROJECT}},
        {"name": "run_p50_latency_ms", "value": stats["p50_ms"],            "unit": "ms",      "tags": {"project": PROJECT}},
        {"name": "run_p99_latency_ms", "value": stats["p99_ms"],            "unit": "ms",      "tags": {"project": PROJECT}},
        {"name": "total_tokens",       "value": float(stats["tokens"]),     "unit": "count",   "tags": {"project": PROJECT}},
        {"name": "total_cost_usd",     "value": stats["cost_usd"],          "unit": "usd",     "tags": {"project": PROJECT}},
    ]

    if EVAL_DS:
        score = latest_eval_score(EVAL_DS)
        if score >= 0:
            metrics.append({"name": "eval_score", "value": score, "unit": "score", "tags": {"dataset": EVAL_DS}})
            print(f"LangSmith: eval_score={score} (dataset={EVAL_DS})")

    fb = feedback_score(start_iso, end_iso)
    if fb >= 0:
        metrics.append({"name": "feedback_score", "value": fb, "unit": "score", "tags": {"project": PROJECT}})
        print(f"LangSmith: feedback_score={fb}")

    output = {
        "provider":     "langsmith",
        "collected_at": now_ts,
        "window":       WINDOW,
        "metrics":      metrics,
        "raw": {"project": PROJECT, "run_type": RUN_TYPE},
    }

    with open("raw-metrics.json", "w") as f:
        json.dump(output, f, indent=2)


if __name__ == "__main__":
    main()
