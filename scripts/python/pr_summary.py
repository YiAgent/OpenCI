#!/usr/bin/env python3
"""Build rolling PR summary comment with ETag-aware upsert.

Aggregates signals from multiple workflows into a single comment.
"""

import json
import os
import sys
import urllib.request


MARKER = "<!-- pr-agent-summary -->"


def find_existing(token: str, repo: str, pr: str):
    """Find existing comment by marker."""
    url = f"https://api.github.com/repos/{repo}/issues/{pr}/comments?per_page=100"
    req = urllib.request.Request(url, headers={
        "Authorization": f"token {token}",
        "Accept": "application/vnd.github.v3+json",
    })
    with urllib.request.urlopen(req) as resp:
        for c in json.loads(resp.read()):
            if MARKER in c.get("body", ""):
                return c["id"], resp.headers.get("ETag")
    return None, None


def upsert(token: str, repo: str, pr: str, body: str) -> dict:
    """Create or update comment with ETag-aware concurrency."""
    cid, etag = find_existing(token, repo, pr)
    full = f"{MARKER}\n{body}"

    if cid:
        url = f"https://api.github.com/repos/{repo}/issues/comments/{cid}"
        req = urllib.request.Request(
            url,
            data=json.dumps({"body": full}).encode(),
            method="PATCH",
            headers={
                "Authorization": f"token {token}",
                "Accept": "application/vnd.github.v3+json",
                "Content-Type": "application/json",
                "If-Match": etag or "",
            },
        )
    else:
        url = f"https://api.github.com/repos/{repo}/issues/{pr}/comments"
        req = urllib.request.Request(
            url,
            data=json.dumps({"body": full}).encode(),
            method="POST",
            headers={
                "Authorization": f"token {token}",
                "Accept": "application/vnd.github.v3+json",
                "Content-Type": "application/json",
            },
        )

    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read())


def build_summary(signals: dict) -> str:
    """Build markdown summary from aggregated signals.

    Args:
        signals: Dict of workflow_name -> {status, details}
    """
    lines = ["## PR Agent Summary\n"]

    risk = signals.get("risk", {})
    risk_level = risk.get("level", "unknown")
    risk_emoji = {"low": "green", "medium": "yellow", "high": "red"}.get(risk_level, "grey")
    lines.append(f"**Risk Level:** :{risk_emoji}: {risk_level.upper()}")
    if risk.get("reason"):
        lines.append(f"> {risk['reason']}\n")

    lines.append("| Check | Status | Details |")
    lines.append("|-------|--------|---------|")
    for name, data in signals.get("checks", {}).items():
        status = "pass" if data.get("passed") else "fail"
        emoji = "white_check_mark" if status == "pass" else "x"
        details = data.get("details", "")
        lines.append(f"| {name} | :{emoji}: {status} | {details} |")

    if signals.get("must_fix"):
        lines.append("\n### Must Fix\n")
        for item in signals["must_fix"]:
            loc = f"`{item['file']}`" if item.get("file") else ""
            line = f" (L{item['line']})" if item.get("line") else ""
            lines.append(f"- {loc}{line}: {item['issue']}")

    return "\n".join(lines)


def main():
    token = os.environ.get("GITHUB_TOKEN", "")
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    pr = os.environ.get("PR_NUMBER", "")
    signals_json = os.environ.get("SIGNALS", "{}")

    if not all([token, repo, pr]):
        print("::error::Missing required env vars", file=sys.stderr)
        sys.exit(1)

    signals = json.loads(signals_json)
    body = build_summary(signals)
    result = upsert(token, repo, pr, body)

    output_file = os.environ.get("GITHUB_OUTPUT")
    if output_file:
        with open(output_file, "a") as f:
            f.write(f"comment_id={result.get('id', '')}\n")
            f.write(f"comment_url={result.get('html_url', '')}\n")


if __name__ == "__main__":
    main()
