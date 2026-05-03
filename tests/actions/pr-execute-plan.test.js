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

function makePlan(overrides = {}) {
  return {
    version: 'pr-action-plan/v1',
    summary: '',
    risk: 'low',
    risk_reason: '',
    reviewer_focus: [],
    actions: [],
    ...overrides,
  };
}

// ── Plan parsing & validation ────────────────────────────────────────────────

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

// ── Sticky comment: creation ─────────────────────────────────────────────────

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

test('empty actions array still posts comment', async () => {
  const created = [];
  const github = makeGithub({
    issues: { createComment: async (args) => created.push(args) },
    paginate: async () => [],
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify(makePlan({ actions: [] })),
  });

  const result = await executePrPlan({ github, context: makeContext(), env });

  assert.equal(created.length, 1);
  assert.ok(created[0].body.includes('OpenCI PR Analysis'));
  assert.deepEqual(result.executed, []);
});

// ── Sticky comment: upsert ───────────────────────────────────────────────────

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

test('existing comment with different run ID marker gets updated (not duplicated)', async () => {
  const created = [];
  const updated = [];
  const github = makeGithub({
    paginate: async () => [{ id: 42, body: '<!-- openci-pr-run:42 -->' }],
    issues: {
      createComment: async (args) => created.push(args),
      updateComment: async (args) => updated.push(args),
    },
  });
  const env = makeEnv({ RUN_ID: '99' });

  await executePrPlan({ github, context: makeContext(), env });

  assert.equal(updated.length, 1);
  assert.equal(updated[0].comment_id, 42);
  assert.equal(created.length, 0, 'should not create a new comment');
});

// ── Sticky comment: body content ─────────────────────────────────────────────

test('comment body includes risk and summary', async () => {
  const created = [];
  const github = makeGithub({
    issues: { createComment: async (args) => created.push(args) },
    paginate: async () => [],
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify(makePlan({
      summary: 'This PR adds a new feature.',
      risk: 'medium',
      risk_reason: 'Touches auth code.',
      reviewer_focus: ['Check token expiry logic'],
    })),
  });

  await executePrPlan({ github, context: makeContext(), env });

  const body = created[0].body;
  assert.ok(body.includes('This PR adds a new feature.'));
  assert.ok(body.includes('medium'));
  assert.ok(body.includes('Touches auth code.'));
  assert.ok(body.includes('Check token expiry logic'));
});

test('comment body includes risk icon for each risk level', async () => {
  const cases = [
    { risk: 'high', icon: '\u{1F534}' },   // red circle
    { risk: 'medium', icon: '\u{1F7E1}' }, // yellow circle
    { risk: 'low', icon: '\u{1F7E2}' },    // green circle
  ];

  for (const { risk, icon } of cases) {
    const created = [];
    const github = makeGithub({
      issues: { createComment: async (args) => created.push(args) },
      paginate: async () => [],
    });
    const env = makeEnv({
      ACTION_PLAN: JSON.stringify(makePlan({ risk, risk_reason: 'test' })),
    });

    await executePrPlan({ github, context: makeContext(), env });

    const body = created[0].body;
    assert.ok(body.includes(icon), `expected icon "${icon}" for risk "${risk}"`);
    assert.ok(body.includes(`\`${risk}\``), `expected risk label for "${risk}"`);
  }
});

test('comment body includes reviewer_focus lines', async () => {
  const created = [];
  const github = makeGithub({
    issues: { createComment: async (args) => created.push(args) },
    paginate: async () => [],
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify(makePlan({
      reviewer_focus: ['Auth flow', 'Rate limiting', 'SQL injection'],
    })),
  });

  await executePrPlan({ github, context: makeContext(), env });

  const body = created[0].body;
  assert.ok(body.includes('- Auth flow'));
  assert.ok(body.includes('- Rate limiting'));
  assert.ok(body.includes('- SQL injection'));
});

test('comment body includes RUN_ID marker', async () => {
  const created = [];
  const github = makeGithub({
    issues: { createComment: async (args) => created.push(args) },
    paginate: async () => [],
  });
  const env = makeEnv({ RUN_ID: '12345' });

  await executePrPlan({ github, context: makeContext(), env });

  const body = created[0].body;
  assert.ok(body.includes('<!-- openci-pr-run:12345 -->'));
});

// ── skip_reason ──────────────────────────────────────────────────────────────

test('skip_reason prevents action execution', async () => {
  const labels = [];
  const github = makeGithub({
    issues: { addLabels: async (args) => labels.push(args), createComment: async () => {} },
    paginate: async () => [],
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify(makePlan({
      actions: [{ skill: 'add_label', params: { labels: ['bug'] }, confidence: 'high' }],
      skip_reason: 'missing-anthropic-api-key',
    })),
  });

  const result = await executePrPlan({ github, context: makeContext(), env });

  assert.equal(result.skipped, true);
  assert.equal(labels.length, 0);
});

test('plan with both skip_reason and actions - skip_reason wins', async () => {
  const labels = [];
  const reviews = [];
  const github = makeGithub({
    issues: {
      addLabels: async (args) => labels.push(args),
      createComment: async () => {},
    },
    pulls: { createReview: async (args) => reviews.push(args) },
    paginate: async () => [],
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify(makePlan({
      actions: [
        { skill: 'add_label', params: { labels: ['bug'] }, confidence: 'high' },
        { skill: 'request_changes', params: { body: 'Fix this.' }, confidence: 'high' },
      ],
      skip_reason: 'missing-anthropic-api-key',
    })),
  });

  const result = await executePrPlan({ github, context: makeContext(), env });

  assert.equal(result.skipped, true);
  assert.equal(result.reason, 'missing-anthropic-api-key');
  assert.equal(labels.length, 0);
  assert.equal(reviews.length, 0);
});

// ── add_label ────────────────────────────────────────────────────────────────

test('add_label executes for high-confidence action', async () => {
  const labels = [];
  const github = makeGithub({
    issues: { addLabels: async (args) => labels.push(...args.labels), createComment: async () => {} },
    paginate: async () => [],
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify(makePlan({
      actions: [{ skill: 'add_label', params: { labels: ['size:S'] }, confidence: 'high' }],
    })),
  });

  await executePrPlan({ github, context: makeContext(), env });

  assert.ok(labels.includes('size:S'));
});

test('add_label with empty labels array is no-op', async () => {
  const addLabelsCalls = [];
  const github = makeGithub({
    issues: { addLabels: async (args) => addLabelsCalls.push(args), createComment: async () => {} },
    paginate: async () => [],
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify(makePlan({
      actions: [{ skill: 'add_label', params: { labels: [] }, confidence: 'high' }],
    })),
  });

  const result = await executePrPlan({ github, context: makeContext(), env });

  assert.equal(addLabelsCalls.length, 0);
  assert.equal(result.executed.length, 0);
});

// ── remove_label ─────────────────────────────────────────────────────────────

test('remove_label executes and ignores 404 errors', async () => {
  const removed = [];
  const github = makeGithub({
    issues: {
      removeLabel: async (args) => {
        if (args.name === 'nonexistent') {
          const err = new Error('Not Found');
          err.status = 404;
          throw err;
        }
        removed.push(args.name);
      },
      createComment: async () => {},
    },
    paginate: async () => [],
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify(makePlan({
      actions: [{ skill: 'remove_label', params: { labels: ['bug', 'nonexistent'] }, confidence: 'high' }],
    })),
  });

  const result = await executePrPlan({ github, context: makeContext(), env });

  assert.ok(removed.includes('bug'));
  assert.ok(result.executed.includes('remove_label: bug'));
});

test('remove_label with non-404 error DOES throw', async () => {
  const github = makeGithub({
    issues: {
      removeLabel: async () => {
        const err = new Error('Server Error');
        err.status = 500;
        throw err;
      },
      createComment: async () => {},
    },
    paginate: async () => [],
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify(makePlan({
      actions: [{ skill: 'remove_label', params: { labels: ['bug'] }, confidence: 'high' }],
    })),
  });

  await assert.rejects(
    () => executePrPlan({ github, context: makeContext(), env }),
    /Server Error/,
  );
});

// ── add_reviewer ─────────────────────────────────────────────────────────────

test('add_reviewer executes for high-confidence action', async () => {
  const reviewerCalls = [];
  const github = makeGithub({
    pulls: { requestReviewers: async (args) => reviewerCalls.push(args) },
    issues: { createComment: async () => {} },
    paginate: async () => [],
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify(makePlan({
      actions: [{ skill: 'add_reviewer', params: { reviewers: ['alice'] }, confidence: 'high' }],
    })),
  });

  await executePrPlan({ github, context: makeContext(), env });

  assert.equal(reviewerCalls.length, 1);
  assert.deepEqual(reviewerCalls[0].reviewers, ['alice']);
});

test('add_reviewer with team_reviewers', async () => {
  const reviewerCalls = [];
  const github = makeGithub({
    pulls: { requestReviewers: async (args) => reviewerCalls.push(args) },
    issues: { createComment: async () => {} },
    paginate: async () => [],
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify(makePlan({
      actions: [{
        skill: 'add_reviewer',
        params: { reviewers: ['alice', 'bob'], team_reviewers: ['security-team'] },
        confidence: 'high',
      }],
    })),
  });

  await executePrPlan({ github, context: makeContext(), env });

  assert.equal(reviewerCalls.length, 1);
  assert.deepEqual(reviewerCalls[0].reviewers, ['alice', 'bob']);
  assert.deepEqual(reviewerCalls[0].team_reviewers, ['security-team']);
});

// ── request_changes ──────────────────────────────────────────────────────────

test('request_changes creates review for high-confidence action', async () => {
  const reviews = [];
  const github = makeGithub({
    pulls: { createReview: async (args) => reviews.push(args) },
    issues: { createComment: async () => {} },
    paginate: async () => [],
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify(makePlan({
      actions: [{ skill: 'request_changes', params: { body: 'Please fix.' }, confidence: 'high' }],
    })),
  });

  await executePrPlan({ github, context: makeContext(), env });

  assert.equal(reviews.length, 1);
  assert.equal(reviews[0].body, 'Please fix.');
  assert.equal(reviews[0].event, 'REQUEST_CHANGES');
});

test('request_changes without body is no-op', async () => {
  const reviews = [];
  const github = makeGithub({
    pulls: { createReview: async (args) => reviews.push(args) },
    issues: { createComment: async () => {} },
    paginate: async () => [],
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify(makePlan({
      actions: [{ skill: 'request_changes', params: {}, confidence: 'high' }],
    })),
  });

  const result = await executePrPlan({ github, context: makeContext(), env });

  assert.equal(reviews.length, 0);
  assert.equal(result.executed.length, 0);
});

// ── block_merge ──────────────────────────────────────────────────────────────

test('block_merge adds do-not-merge label', async () => {
  const labels = [];
  const github = makeGithub({
    issues: { addLabels: async (args) => labels.push(...args.labels), createComment: async () => {} },
    paginate: async () => [],
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify(makePlan({
      actions: [{ skill: 'block_merge', params: { reason: 'Breaking change detected.' }, confidence: 'high' }],
    })),
  });

  await executePrPlan({ github, context: makeContext(), env });

  assert.ok(labels.includes('do-not-merge'));
});

test('block_merge with reason posts a separate comment', async () => {
  const comments = [];
  const github = makeGithub({
    issues: {
      addLabels: async () => {},
      createComment: async (args) => comments.push(args),
    },
    paginate: async () => [],
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify(makePlan({
      actions: [{ skill: 'block_merge', params: { reason: 'Security vulnerability.' }, confidence: 'high' }],
    })),
  });

  await executePrPlan({ github, context: makeContext(), env });

  // 2 calls: sticky summary + block_merge reason comment
  assert.equal(comments.length, 2);
  const blockComment = comments.find((c) => c.body.includes('Block merge'));
  assert.ok(blockComment);
  assert.ok(blockComment.body.includes('Security vulnerability.'));
  assert.ok(blockComment.body.includes('openci-block-merge'));
});

test('block_merge without reason does not post extra comment', async () => {
  const comments = [];
  const github = makeGithub({
    issues: {
      addLabels: async () => {},
      createComment: async (args) => comments.push(args),
    },
    paginate: async () => [],
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify(makePlan({
      actions: [{ skill: 'block_merge', params: {}, confidence: 'high' }],
    })),
  });

  await executePrPlan({ github, context: makeContext(), env });

  // Only the sticky summary comment, no block_merge reason comment
  assert.equal(comments.length, 1);
  assert.ok(comments[0].body.includes('OpenCI PR Analysis'));
});

// ── assign_issue ─────────────────────────────────────────────────────────────

test('assign_issue executes for high-confidence action', async () => {
  const assignCalls = [];
  const github = makeGithub({
    issues: {
      addAssignees: async (args) => assignCalls.push(args),
      createComment: async () => {},
    },
    paginate: async () => [],
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify(makePlan({
      actions: [{ skill: 'assign_issue', params: { assignees: ['alice'] }, confidence: 'high' }],
    })),
  });

  await executePrPlan({ github, context: makeContext(), env });

  assert.equal(assignCalls.length, 1);
  assert.deepEqual(assignCalls[0].assignees, ['alice']);
});

test('assign_issue with empty assignees still calls API', async () => {
  const assignCalls = [];
  const github = makeGithub({
    issues: {
      addAssignees: async (args) => assignCalls.push(args),
      createComment: async () => {},
    },
    paginate: async () => [],
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify(makePlan({
      actions: [{ skill: 'assign_issue', params: { assignees: [] }, confidence: 'high' }],
    })),
  });

  const result = await executePrPlan({ github, context: makeContext(), env });

  assert.equal(assignCalls.length, 1);
  assert.deepEqual(assignCalls[0].assignees, []);
  assert.ok(result.executed.includes('assign_issue'));
});

// ── escalate ─────────────────────────────────────────────────────────────────

test('escalate defaults to needs-human label', async () => {
  const labels = [];
  const github = makeGithub({
    issues: { addLabels: async (args) => labels.push(...args.labels), createComment: async () => {} },
    paginate: async () => [],
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify(makePlan({
      actions: [{ skill: 'escalate', params: {}, confidence: 'high' }],
    })),
  });

  const result = await executePrPlan({ github, context: makeContext(), env });

  assert.ok(labels.includes('needs-human'));
  assert.ok(result.executed.includes('escalate: needs-human'));
});

test('escalate with custom labels', async () => {
  const labels = [];
  const github = makeGithub({
    issues: { addLabels: async (args) => labels.push(...args.labels), createComment: async () => {} },
    paginate: async () => [],
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify(makePlan({
      actions: [{ skill: 'escalate', params: { labels: ['security', 'urgent'] }, confidence: 'high' }],
    })),
  });

  const result = await executePrPlan({ github, context: makeContext(), env });

  assert.ok(labels.includes('security'));
  assert.ok(labels.includes('urgent'));
  assert.ok(result.executed.includes('escalate: security, urgent'));
});

test('escalate with empty labels defaults to needs-human', async () => {
  const labels = [];
  const github = makeGithub({
    issues: { addLabels: async (args) => labels.push(...args.labels), createComment: async () => {} },
    paginate: async () => [],
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify(makePlan({
      actions: [{ skill: 'escalate', params: { labels: [] }, confidence: 'high' }],
    })),
  });

  const result = await executePrPlan({ github, context: makeContext(), env });

  assert.ok(labels.includes('needs-human'));
  assert.ok(result.executed.includes('escalate: needs-human'));
});

// ── Confidence filtering ─────────────────────────────────────────────────────

test('low-confidence actions are skipped', async () => {
  const labels = [];
  const github = makeGithub({
    issues: { addLabels: async (args) => labels.push(...args.labels), createComment: async () => {} },
    paginate: async () => [],
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify(makePlan({
      actions: [{ skill: 'add_label', params: { labels: ['bug'] }, confidence: 'low' }],
    })),
  });

  await executePrPlan({ github, context: makeContext(), env });

  assert.equal(labels.length, 0);
});

test('medium-confidence actions are skipped', async () => {
  const labels = [];
  const github = makeGithub({
    issues: { addLabels: async (args) => labels.push(...args.labels), createComment: async () => {} },
    paginate: async () => [],
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify(makePlan({
      actions: [{ skill: 'add_label', params: { labels: ['bug'] }, confidence: 'medium' }],
    })),
  });

  await executePrPlan({ github, context: makeContext(), env });

  assert.equal(labels.length, 0);
});

// ── Trust gating ─────────────────────────────────────────────────────────────

test('high-risk skill blocked for untrusted actor', async () => {
  const reviews = [];
  const github = makeGithub({
    pulls: { createReview: async (args) => reviews.push(args) },
    issues: { createComment: async () => {} },
    paginate: async () => [],
  });
  const env = makeEnv({
    TRUSTED: 'false',
    ACTION_PLAN: JSON.stringify(makePlan({
      actions: [{ skill: 'request_changes', params: { body: 'Please fix.' }, confidence: 'high' }],
    })),
  });

  await executePrPlan({ github, context: makeContext(), env });

  assert.equal(reviews.length, 0);
});

test('mixed trusted/untrusted actions - only low-risk ones execute', async () => {
  const labels = [];
  const reviews = [];
  const github = makeGithub({
    issues: {
      addLabels: async (args) => labels.push(...args.labels),
      createComment: async () => {},
    },
    pulls: { createReview: async (args) => reviews.push(args) },
    paginate: async () => [],
  });
  const env = makeEnv({
    TRUSTED: 'false',
    ACTION_PLAN: JSON.stringify(makePlan({
      actions: [
        { skill: 'add_label', params: { labels: ['size:S'] }, confidence: 'high' },
        { skill: 'request_changes', params: { body: 'Fix this.' }, confidence: 'high' },
        { skill: 'add_label', params: { labels: ['enhancement'] }, confidence: 'high' },
      ],
    })),
  });

  const result = await executePrPlan({ github, context: makeContext(), env });

  assert.ok(labels.includes('size:S'));
  assert.ok(labels.includes('enhancement'));
  assert.equal(reviews.length, 0);
  assert.equal(result.executed.length, 2);
});

// ── Unknown skills ───────────────────────────────────────────────────────────

test('unknown skill names are silently skipped', async () => {
  const addLabelsCalls = [];
  const github = makeGithub({
    issues: { addLabels: async (args) => addLabelsCalls.push(args), createComment: async () => {} },
    paginate: async () => [],
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify(makePlan({
      actions: [
        { skill: 'deploy_to_prod', params: {}, confidence: 'high' },
        { skill: 'add_label', params: { labels: ['ready'] }, confidence: 'high' },
        { skill: 'magic_spell', params: {}, confidence: 'high' },
      ],
    })),
  });

  const result = await executePrPlan({ github, context: makeContext(), env });

  assert.equal(addLabelsCalls.length, 1);
  assert.deepEqual(addLabelsCalls[0].labels, ['ready']);
  assert.equal(result.executed.length, 1);
  assert.ok(result.executed.includes('add_label: ready'));
});

// ── Multiple actions in sequence ─────────────────────────────────────────────

test('multiple actions execute in sequence', async () => {
  const labels = [];
  const reviewerCalls = [];
  const github = makeGithub({
    issues: {
      addLabels: async (args) => labels.push(...args.labels),
      createComment: async () => {},
    },
    pulls: { requestReviewers: async (args) => reviewerCalls.push(args) },
    paginate: async () => [],
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify(makePlan({
      actions: [
        { skill: 'add_label', params: { labels: ['size:M'] }, confidence: 'high' },
        { skill: 'add_reviewer', params: { reviewers: ['carol'] }, confidence: 'high' },
        { skill: 'add_label', params: { labels: ['needs-review'] }, confidence: 'high' },
      ],
    })),
  });

  const result = await executePrPlan({ github, context: makeContext(), env });

  assert.ok(labels.includes('size:M'));
  assert.ok(labels.includes('needs-review'));
  assert.equal(reviewerCalls.length, 1);
  assert.deepEqual(reviewerCalls[0].reviewers, ['carol']);
  assert.equal(result.executed.length, 3);
  assert.deepEqual(result.executed, [
    'add_label: size:M',
    'add_reviewer',
    'add_label: needs-review',
  ]);
});

// ── Return value ─────────────────────────────────────────────────────────────

test('returns executed actions list on success', async () => {
  const github = makeGithub({
    issues: { addLabels: async () => {}, createComment: async () => {} },
    paginate: async () => [],
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify(makePlan({
      actions: [
        { skill: 'add_label', params: { labels: ['bug'] }, confidence: 'high' },
        { skill: 'add_label', params: { labels: ['p1'] }, confidence: 'high' },
      ],
    })),
  });

  const result = await executePrPlan({ github, context: makeContext(), env });

  assert.equal(result.skipped, false);
  assert.equal(result.executed.length, 2);
});

test('returns skipped=false when no skip_reason', async () => {
  const github = makeGithub({
    issues: { createComment: async () => {} },
    paginate: async () => [],
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify(makePlan({ actions: [] })),
  });

  const result = await executePrPlan({ github, context: makeContext(), env });

  assert.equal(result.skipped, false);
});
