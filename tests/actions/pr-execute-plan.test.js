'use strict';
// Unit tests for actions/pr/execute-plan/execute.js
// Run with: node --test tests/actions/pr-execute-plan.test.js

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { executePrPlan } = require('../../actions/pr/execute-plan/execute.js');

// ── Helpers ──────────────────────────────────────────────────────────────────

function makeGithub(overrides = {}) {
  const issues = {
    listComments: async () => ({ data: [] }),
    createComment: async () => {},
    updateComment: async () => {},
    addLabels: async () => {},
    removeLabel: async () => {},
    addAssignees: async () => {},
  };
  const pulls = {
    requestReviewers: async () => {},
    createReview: async () => {},
  };
  return {
    rest: {
      issues: { ...issues, ...(overrides.issues || {}) },
      pulls: { ...pulls, ...(overrides.pulls || {}) },
    },
    paginate: async (_fn, _opts) => [],
    ...overrides,
  };
}

function makeContext(pr = 5) {
  return {
    repo: { owner: 'YiAgent', repo: 'OpenCI' },
    payload: { pull_request: { number: pr } },
    runId: 77,
  };
}

function makeEnv(overrides = {}) {
  return {
    ACTION_PLAN: JSON.stringify({
      version: 'pr-action-plan/v1',
      summary: 'Looks good.',
      risk: 'low',
      risk_reason: 'Small change.',
      reviewer_focus: [],
      actions: [],
    }),
    TRUSTED: 'true',
    RUN_ID: '77',
    ...overrides,
  };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test('wrong plan version throws', async () => {
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify({ version: 'bad/v99', actions: [] }),
  });
  await assert.rejects(
    () => executePrPlan({ github: makeGithub(), context: makeContext(), env }),
    /Unsupported plan version/,
  );
});

test('missing pull_request returns skipped', async () => {
  const context = { repo: { owner: 'YiAgent', repo: 'OpenCI' }, payload: {}, runId: 1 };
  const result = await executePrPlan({ github: makeGithub(), context, env: makeEnv() });
  assert.equal(result.skipped, true);
});

test('creates sticky comment when none exists', async () => {
  const created = [];
  const github = makeGithub({
    issues: { createComment: async (args) => created.push(args) },
    paginate: async () => [],
  });

  await executePrPlan({ github, context: makeContext(), env: makeEnv() });

  assert.equal(created.length, 1);
  assert.ok(created[0].body.includes('OpenCI PR Analysis'));
});

test('updates existing sticky comment instead of creating new one', async () => {
  const updated = [];
  const github = makeGithub({
    paginate: async () => [{ id: 999, body: '<!-- openci-pr-run:old -->' }],
    issues: { updateComment: async (args) => updated.push(args) },
  });

  await executePrPlan({ github, context: makeContext(), env: makeEnv() });

  assert.equal(updated.length, 1);
  assert.equal(updated[0].comment_id, 999);
});

test('skip_reason prevents action execution', async () => {
  const labels = [];
  const github = makeGithub({
    issues: { addLabels: async (args) => labels.push(args), createComment: async () => {} },
    paginate: async () => [],
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify({
      version: 'pr-action-plan/v1',
      summary: '',
      risk: 'low',
      risk_reason: '',
      reviewer_focus: [],
      actions: [{ skill: 'add_label', params: { labels: ['bug'] }, confidence: 'high' }],
      skip_reason: 'missing-anthropic-api-key',
    }),
  });

  const result = await executePrPlan({ github, context: makeContext(), env });

  assert.equal(result.skipped, true);
  assert.equal(labels.length, 0);
});

test('add_label executes for high-confidence action', async () => {
  const labels = [];
  const github = makeGithub({
    issues: { addLabels: async (args) => labels.push(...args.labels), createComment: async () => {} },
    paginate: async () => [],
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify({
      version: 'pr-action-plan/v1',
      summary: '', risk: 'low', risk_reason: '', reviewer_focus: [],
      actions: [{ skill: 'add_label', params: { labels: ['size:S'] }, confidence: 'high' }],
    }),
  });

  await executePrPlan({ github, context: makeContext(), env });

  assert.ok(labels.includes('size:S'));
});

test('low-confidence actions are skipped', async () => {
  const labels = [];
  const github = makeGithub({
    issues: { addLabels: async (args) => labels.push(...args.labels), createComment: async () => {} },
    paginate: async () => [],
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify({
      version: 'pr-action-plan/v1',
      summary: '', risk: 'low', risk_reason: '', reviewer_focus: [],
      actions: [{ skill: 'add_label', params: { labels: ['bug'] }, confidence: 'low' }],
    }),
  });

  await executePrPlan({ github, context: makeContext(), env });

  assert.equal(labels.length, 0);
});

test('high-risk skill blocked for untrusted actor', async () => {
  const reviews = [];
  const github = makeGithub({
    pulls: { createReview: async (args) => reviews.push(args) },
    issues: { createComment: async () => {} },
    paginate: async () => [],
  });
  const env = makeEnv({
    TRUSTED: 'false',
    ACTION_PLAN: JSON.stringify({
      version: 'pr-action-plan/v1',
      summary: '', risk: 'high', risk_reason: '', reviewer_focus: [],
      actions: [{ skill: 'request_changes', params: { body: 'Please fix.' }, confidence: 'high' }],
    }),
  });

  await executePrPlan({ github, context: makeContext(), env });

  assert.equal(reviews.length, 0);
});

test('block_merge adds do-not-merge label', async () => {
  const labels = [];
  const github = makeGithub({
    issues: { addLabels: async (args) => labels.push(...args.labels), createComment: async () => {} },
    paginate: async () => [],
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify({
      version: 'pr-action-plan/v1',
      summary: '', risk: 'high', risk_reason: '', reviewer_focus: [],
      actions: [{ skill: 'block_merge', params: { reason: 'Breaking change detected.' }, confidence: 'high' }],
    }),
  });

  await executePrPlan({ github, context: makeContext(), env });

  assert.ok(labels.includes('do-not-merge'));
});

test('escalate defaults to needs-human label', async () => {
  const labels = [];
  const github = makeGithub({
    issues: { addLabels: async (args) => labels.push(...args.labels), createComment: async () => {} },
    paginate: async () => [],
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify({
      version: 'pr-action-plan/v1',
      summary: '', risk: 'low', risk_reason: '', reviewer_focus: [],
      actions: [{ skill: 'escalate', params: {}, confidence: 'high' }],
    }),
  });

  await executePrPlan({ github, context: makeContext(), env });

  assert.ok(labels.includes('needs-human'));
});

test('comment body includes risk and summary', async () => {
  const created = [];
  const github = makeGithub({
    issues: { createComment: async (args) => created.push(args) },
    paginate: async () => [],
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify({
      version: 'pr-action-plan/v1',
      summary: 'This PR adds a new feature.',
      risk: 'medium',
      risk_reason: 'Touches auth code.',
      reviewer_focus: ['Check token expiry logic'],
      actions: [],
    }),
  });

  await executePrPlan({ github, context: makeContext(), env });

  const body = created[0].body;
  assert.ok(body.includes('This PR adds a new feature.'));
  assert.ok(body.includes('medium'));
  assert.ok(body.includes('Touches auth code.'));
  assert.ok(body.includes('Check token expiry logic'));
});
