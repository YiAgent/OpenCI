#!/usr/bin/env python3
"""Emit deployment annotations to external observability platforms.

Supports Sentry, Axiom, Datadog, and PostHog.
"""

import json
import os
import sys
import urllib.request


def annotate_sentry(auth_token: str, org: str, project: str, sha: str, environment: str):
    """Create a Sentry release."""
    url = f"https://sentry.io/api/0/organizations/{org}/releases/"
    data = json.dumps({
        "version": sha,
        "projects": [project],
        "environment": environment,
    }).encode()
    req = urllib.request.Request(url, data=data, headers={
        "Authorization": f"Bearer {auth_token}",
        "Content-Type": "application/json",
    })
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        print(f"::warning::Sentry annotation failed: {e.code}", file=sys.stderr)
        return None


def annotate_axiom(token: str, dataset: str, sha: str, environment: str):
    """Ingest deployment event to Axiom."""
    url = f"https://api.axiom.co/v1/datasets/{dataset}/ingest"
    data = json.dumps([{
        "environment": environment,
        "commit": sha,
        "deployer": "ci",
        "timestamp": __import__("datetime").datetime.utcnow().isoformat() + "Z",
    }]).encode()
    req = urllib.request.Request(url, data=data, headers={
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    })
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        print(f"::warning::Axiom annotation failed: {e.code}", file=sys.stderr)
        return None


def annotate_datadog(api_key: str, sha: str, environment: str):
    """Send deployment event to Datadog."""
    url = "https://api.datadoghq.com/api/v1/events"
    data = json.dumps({
        "title": f"Deploy to {environment}",
        "text": f"Commit {sha}",
        "tags": [f"env:{environment}", f"commit:{sha[:8]}"],
    }).encode()
    req = urllib.request.Request(url, data=data, headers={
        "DD-API-KEY": api_key,
        "Content-Type": "application/json",
    })
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        print(f"::warning::Datadog annotation failed: {e.code}", file=sys.stderr)
        return None


def annotate_posthog(api_key: str, project_id: str, sha: str, environment: str):
    """Create PostHog annotation."""
    url = f"https://app.posthog.com/api/projects/{project_id}/annotations/"
    data = json.dumps({
        "content": f"Deploy {sha[:8]} to {environment}",
        "scope": "organization",
    }).encode()
    req = urllib.request.Request(url, data=data, headers={
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    })
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        print(f"::warning::PostHog annotation failed: {e.code}", file=sys.stderr)
        return None


def main():
    sha = os.environ.get("GITHUB_SHA", "")
    environment = os.environ.get("ENVIRONMENT", "staging")

    results = {}

    sentry_token = os.environ.get("SENTRY_AUTH_TOKEN", "")
    if sentry_token:
        results["sentry"] = annotate_sentry(
            sentry_token,
            os.environ.get("SENTRY_ORG", ""),
            os.environ.get("SENTRY_PROJECT", ""),
            sha, environment,
        )

    axiom_token = os.environ.get("AXIOM_TOKEN", "")
    if axiom_token:
        results["axiom"] = annotate_axiom(
            axiom_token,
            os.environ.get("AXIOM_DATASET", "deployments"),
            sha, environment,
        )

    dd_key = os.environ.get("DATADOG_API_KEY", "")
    if dd_key:
        results["datadog"] = annotate_datadog(dd_key, sha, environment)

    ph_key = os.environ.get("POSTHOG_API_KEY", "")
    if ph_key:
        results["posthog"] = annotate_posthog(
            ph_key,
            os.environ.get("POSTHOG_PROJECT_ID", ""),
            sha, environment,
        )

    if not results:
        print("::notice::No observability tokens found, skipping annotations")

    print(f"Annotated {len(results)} platforms: {', '.join(results.keys())}")


if __name__ == "__main__":
    main()
