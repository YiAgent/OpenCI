#!/usr/bin/env python3
"""Parse gate context JSON and determine if the current workflow should run."""

import json
import os
import sys


def parse_gate_context(context_path: str, area: str) -> dict:
    """Parse gate context and determine run eligibility.

    Args:
        context_path: Path to gate-context.json
        area: Area to check (backend/frontend/docs/infra/ci), empty = always run if gate ok

    Returns:
        Dict with gate_ok, should_run, pr_number, head_sha
    """
    try:
        with open(context_path) as f:
            ctx = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError) as e:
        print(f"::error::Failed to read gate context: {e}", file=sys.stderr)
        return {
            "gate_ok": "false",
            "should_run": "false",
            "pr_number": "",
            "head_sha": "",
        }

    gate_ok = ctx.get("gate_result") == "success"
    pr_number = str(ctx.get("pr_number", ""))
    head_sha = ctx.get("head_sha", "")

    # If no area specified, run if gate passed
    if not area:
        should_run = gate_ok
    else:
        changes = ctx.get("changes", {})
        area_changed = changes.get(area, False)
        should_run = gate_ok and area_changed

    return {
        "gate_ok": str(gate_ok).lower(),
        "should_run": str(should_run).lower(),
        "pr_number": pr_number,
        "head_sha": head_sha,
    }


def main():
    if len(sys.argv) < 2:
        print("Usage: parse.py <context_path> [area]", file=sys.stderr)
        sys.exit(1)

    context_path = sys.argv[1]
    area = sys.argv[2] if len(sys.argv) > 2 else ""

    result = parse_gate_context(context_path, area)

    # Write outputs to GITHUB_OUTPUT
    output_file = os.environ.get("GITHUB_OUTPUT")
    if output_file:
        with open(output_file, "a") as f:
            for key, value in result.items():
                f.write(f"{key}={value}\n")
    else:
        # Fallback: print for debugging
        for key, value in result.items():
            print(f"{key}={value}")


if __name__ == "__main__":
    main()
