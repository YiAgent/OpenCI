#!/usr/bin/env python3
"""ETag-aware PR comment upsert with marker-based deduplication."""

import json
import os
import sys
import urllib.request


def find_existing_comment(token: str, repo: str, pr_number: str, marker: str):
    """Find existing comment by marker. Returns (comment_id, etag) or (None, None)."""
    url = f"https://api.github.com/repos/{repo}/issues/{pr_number}/comments?per_page=100"
    req = urllib.request.Request(url, headers={
        "Authorization": f"token {token}",
        "Accept": "application/vnd.github.v3+json",
    })
    with urllib.request.urlopen(req) as resp:
        comments = json.loads(resp.read())
        etag = resp.headers.get("ETag")
        for c in comments:
            if marker in c.get("body", ""):
                return c["id"], etag
    return None, None


def upsert_comment(token: str, repo: str, pr_number: str, body: str, marker: str) -> dict:
    """Create or update a PR comment with ETag-aware PATCH."""
    comment_id, etag = find_existing_comment(token, repo, pr_number, marker)
    full_body = f"{marker}\n{body}"

    if comment_id:
        url = f"https://api.github.com/repos/{repo}/issues/comments/{comment_id}"
        data = json.dumps({"body": full_body}).encode()
        req = urllib.request.Request(url, data=data, method="PATCH", headers={
            "Authorization": f"token {token}",
            "Accept": "application/vnd.github.v3+json",
            "Content-Type": "application/json",
            "If-Match": etag or "",
        })
    else:
        url = f"https://api.github.com/repos/{repo}/issues/{pr_number}/comments"
        data = json.dumps({"body": full_body}).encode()
        req = urllib.request.Request(url, data=data, method="POST", headers={
            "Authorization": f"token {token}",
            "Accept": "application/vnd.github.v3+json",
            "Content-Type": "application/json",
        })

    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read())


def main():
    token = os.environ.get("GITHUB_TOKEN", "")
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    pr_number = os.environ.get("PR_NUMBER", "")
    body = os.environ.get("COMMENT_BODY", "")
    marker = os.environ.get("COMMENT_MARKER", "<!-- pr-agent-summary -->")

    if not all([token, repo, pr_number, body]):
        print("::error::Missing required environment variables", file=sys.stderr)
        sys.exit(1)

    result = upsert_comment(token, repo, pr_number, body, marker)

    output_file = os.environ.get("GITHUB_OUTPUT")
    if output_file:
        with open(output_file, "a") as f:
            f.write(f"comment_id={result.get('id', '')}\n")

    print(f"Comment upserted: {result.get('html_url', '')}")


if __name__ == "__main__":
    main()
