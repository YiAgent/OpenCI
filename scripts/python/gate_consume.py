#!/usr/bin/env python3
"""Shared gate context consumer script.

Used by gate-consume action and reusable-gate-check workflow.
Reads gate-context.json and outputs run eligibility.
"""

import json
import os
import sys


def consume_gate(context_path: str, area: str = "") -> dict:
    """Parse gate context and return run eligibility.

    Args:
        context_path: Path to gate-context.json
        area: Area to check, empty = run if gate passed

    Returns:
        Dict with gate_ok, should_run, pr_number, head_sha, gate_result
    """
    try:
        with open(context_path) as f:
            ctx = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError) as e:
        return {
            "gate_ok": "false",
            "should_run": "false",
            "pr_number": "",
            "head_sha": "",
            "gate_result": "error",
            "error": str(e),
        }

    gate_result = ctx.get("gate_result", "unknown")
    gate_ok = gate_result == "success"
    pr_number = str(ctx.get("pr_number", ""))
    head_sha = ctx.get("head_sha", "")

    if not area:
        should_run = gate_ok
    else:
        changes = ctx.get("changes", {})
        should_run = gate_ok and changes.get(area, False)

    return {
        "gate_ok": str(gate_ok).lower(),
        "should_run": str(should_run).lower(),
        "pr_number": pr_number,
        "head_sha": head_sha,
        "gate_result": gate_result,
    }


def write_outputs(result: dict):
    """Write outputs to GITHUB_OUTPUT file."""
    output_file = os.environ.get("GITHUB_OUTPUT")
    if output_file:
        with open(output_file, "a") as f:
            for key, value in result.items():
                f.write(f"{key}={value}\n")
    else:
        for key, value in result.items():
            print(f"{key}={value}")


def main():
    if len(sys.argv) < 2:
        print("Usage: gate_consume.py <context_path> [area]", file=sys.stderr)
        sys.exit(1)

    context_path = sys.argv[1]
    area = sys.argv[2] if len(sys.argv) > 2 else ""
    result = consume_gate(context_path, area)
    write_outputs(result)


if __name__ == "__main__":
    main()
