// ─────────────────────────────────────────────────────────────────────────
// Cloudflare Worker: Linear webhook → GitHub repository_dispatch.
// ─────────────────────────────────────────────────────────────────────────
// Verifies the Linear webhook signature, then forwards the issue payload
// as a `repository_dispatch` event of type `linear-issue-started`.
//
// Wrangler env-vars expected:
//   LINEAR_WEBHOOK_SIGNING_SECRET — from Linear's webhook config
//   GITHUB_TOKEN                  — fine-grained PAT with `dispatch` scope
//   GITHUB_OWNER                  — owner segment of target repo
//   GITHUB_REPO                   — repo name
// ─────────────────────────────────────────────────────────────────────────

interface LinearWebhook {
  action: string;
  type: string;
  data: {
    id: string;             // UUID
    identifier: string;     // human id "AIC-123"
    title: string;
    labels?: { name: string }[];
    state: { name: string };
  };
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    if (req.method !== "POST") return new Response("Method Not Allowed", { status: 405 });

    const raw = await req.text();
    const signature = req.headers.get("Linear-Signature") ?? "";
    if (!(await verify(raw, signature, env.LINEAR_WEBHOOK_SIGNING_SECRET))) {
      return new Response("Invalid signature", { status: 401 });
    }

    const payload = JSON.parse(raw) as LinearWebhook;

    // Only fire on Issue → "In Progress" transitions.
    if (payload.type !== "Issue") return new Response("ignored: not an Issue", { status: 200 });
    if (payload.action !== "update") return new Response("ignored: not an update", { status: 200 });
    if (payload.data.state?.name !== "In Progress") {
      return new Response("ignored: state not In Progress", { status: 200 });
    }

    const dispatchBody = {
      event_type: "linear-issue-started",
      client_payload: {
        id:     payload.data.identifier,
        title:  payload.data.title,
        labels: (payload.data.labels ?? []).map((l) => l.name).join(","),
        uuid:   payload.data.id,
        base_branch: "main",
      },
    };

    const ghRes = await fetch(
      `https://api.github.com/repos/${env.GITHUB_OWNER}/${env.GITHUB_REPO}/dispatches`,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${env.GITHUB_TOKEN}`,
          Accept: "application/vnd.github+json",
          "User-Agent": "linear-webhook-bridge",
          "Content-Type": "application/json",
        },
        body: JSON.stringify(dispatchBody),
      }
    );
    if (!ghRes.ok) {
      const detail = await ghRes.text();
      return new Response(`GitHub dispatch failed: ${ghRes.status} ${detail}`, { status: 500 });
    }
    return new Response("dispatched", { status: 202 });
  },
};

async function verify(raw: string, signature: string, secret: string): Promise<boolean> {
  if (!signature || !secret) return false;
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const mac = await crypto.subtle.sign("HMAC", key, enc.encode(raw));
  const hex = [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, "0")).join("");
  // Constant-time compare.
  if (hex.length !== signature.length) return false;
  let mismatch = 0;
  for (let i = 0; i < hex.length; i++) mismatch |= hex.charCodeAt(i) ^ signature.charCodeAt(i);
  return mismatch === 0;
}

interface Env {
  LINEAR_WEBHOOK_SIGNING_SECRET: string;
  GITHUB_TOKEN: string;
  GITHUB_OWNER: string;
  GITHUB_REPO: string;
}
