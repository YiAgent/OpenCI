'use strict';
// Unit tests for actions/issue/execute-plan/execute.js
// Run with: node --test tests/actions/issue-execute-plan.test.js

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { executeIssuePlan } = require('../../actions/issue/execute-plan/execute.js');

// ── Helpers ──────────────────────────────────────────────────────────────────

function makeGithub(overrides = {}) {
  const issues = {
    addLabels: async () => {},
    removeLabel: async () => {},
    addAssignees: async () => {},
    createComment: async () => {},
    update: async () => {},
    listComments: async () => ({ data: [] }),
  };
  const git = {
    getRef: async () => ({ data: { object: { sha: 'abc123' } } }),
    createRef: async () => {},
  };
  return {
    rest: { issues: { ...issues, ...overrides.issues }, git: { ...git, ...overrides.git } },
    paginate: async (_fn, _opts) => [],
    ...overrides,
  };
}

function makeContext(overrides = {}) {
  return {
    repo: { owner: 'YiAgent', repo: 'OpenCI' },
    runId: 99,
    ...overrides,
  };
}

function makeEnv(overrides = {}) {
  return {
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [],
    }),
    PLAN_HASH: 'testhash',
    ISSUE_NUMBER: '42',
    AUTHOR_ASSOC: 'OWNER',
    DEFAULT_BRANCH: 'main',
    WORKSPACE_PATH: '/tmp/nonexistent-workspace',
    ...overrides,
  };
}

function okFetch() {
  return async () => ({ ok: true, text: async () => '' });
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test('empty actions list — no GitHub API calls, returns empty audit', async () => {
  const called = [];
  const github = makeGithub({
    issues: { addLabels: async () => called.push('addLabels') },
  });

  const audit = await executeIssuePlan({
    github, context: makeContext(), env: makeEnv(), fetchFn: okFetch(),
  });

  assert.deepEqual(audit, []);
  assert.deepEqual(called, []);
});

test('wrong plan version throws', async () => {
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify({ version: 'bad/v99', actions: [] }),
  });
  await assert.rejects(
    () => executeIssuePlan({ github: makeGithub(), context: makeContext(), env, fetchFn: okFetch() }),
    /Unsupported plan version/,
  );
});

test('unknown skill throws', async () => {
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'hack_the_planet', params: {} }],
    }),
  });
  await assert.rejects(
    () => executeIssuePlan({ github: makeGithub(), context: makeContext(), env, fetchFn: okFetch() }),
    /Unknown issue agent skill/,
  );
});

test('add_label calls addLabels with correct args', async () => {
  const calls = [];
  const github = makeGithub({
    issues: { addLabels: async (args) => calls.push(args) },
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'add_label', params: { labels: ['bug', 'priority:p1'] } }],
    }),
  });

  await executeIssuePlan({ github, context: makeContext(), env, fetchFn: okFetch() });

  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0].labels, ['bug', 'priority:p1']);
  assert.equal(calls[0].issue_number, 42);
});

test('remove_label ignores 404 errors', async () => {
  const github = makeGithub({
    issues: {
      removeLabel: async () => { const e = new Error('not found'); e.status = 404; throw e; },
    },
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'remove_label', params: { labels: ['stale'] } }],
    }),
  });

  // Should not throw despite 404
  await assert.doesNotReject(() =>
    executeIssuePlan({ github, context: makeContext(), env, fetchFn: okFetch() }),
  );
});

test('close_issue calls update with state closed', async () => {
  const calls = [];
  const github = makeGithub({
    issues: { update: async (args) => calls.push(args) },
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'close_issue', params: {} }],
    }),
  });

  await executeIssuePlan({ github, context: makeContext(), env, fetchFn: okFetch() });

  assert.equal(calls[0].state, 'closed');
  assert.equal(calls[0].state_reason, 'completed');
});

test('close_issue with not_planned reason sets state_reason correctly', async () => {
  const calls = [];
  const github = makeGithub({
    issues: { update: async (args) => calls.push(args) },
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'close_issue', params: { reason: 'not_planned' } }],
    }),
  });

  await executeIssuePlan({ github, context: makeContext(), env, fetchFn: okFetch() });

  assert.equal(calls[0].state_reason, 'not_planned');
});

test('close_issue blocked for untrusted actor', async () => {
  const calls = [];
  const github = makeGithub({
    issues: { update: async (args) => calls.push(args) },
  });
  const env = makeEnv({
    AUTHOR_ASSOC: 'NONE',
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'close_issue', params: {} }],
    }),
  });

  await executeIssuePlan({ github, context: makeContext(), env, fetchFn: okFetch() });

  assert.equal(calls.length, 0, 'close_issue must be blocked for untrusted actor');
});

test('set_priority removes old labels then adds new one', async () => {
  const removed = [];
  const added = [];
  const github = makeGithub({
    issues: {
      removeLabel: async (args) => removed.push(args.name),
      addLabels: async (args) => added.push(...args.labels),
    },
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'set_priority', params: { priority: 'p1' } }],
    }),
  });

  await executeIssuePlan({ github, context: makeContext(), env, fetchFn: okFetch() });

  assert.ok(removed.includes('priority:p0'));
  assert.ok(removed.includes('priority:p2'));
  assert.ok(added.includes('priority:p1'));
});

test('mark_duplicate adds duplicate label and comment', async () => {
  const labels = [];
  const comments = [];
  const github = makeGithub({
    issues: {
      addLabels: async (args) => labels.push(...args.labels),
      createComment: async (args) => comments.push(args.body),
    },
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'mark_duplicate', params: { duplicate_of: 7 } }],
    }),
  });

  await executeIssuePlan({ github, context: makeContext(), env, fetchFn: okFetch() });

  assert.ok(labels.includes('duplicate'));
  assert.ok(comments[0].includes('#7'));
});

test('schedule_followup rejects invalid due_at', async () => {
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'schedule_followup', params: { due_at: 'not-a-date' } }],
    }),
  });
  await assert.rejects(
    () => executeIssuePlan({ github: makeGithub(), context: makeContext(), env, fetchFn: okFetch() }),
    /Invalid schedule_followup due_at/,
  );
});

test('schedule_followup rejects days out of range', async () => {
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'schedule_followup', params: { days: 0 } }],
    }),
  });
  await assert.rejects(
    () => executeIssuePlan({ github: makeGithub(), context: makeContext(), env, fetchFn: okFetch() }),
    /schedule_followup requires due_at or days/,
  );
});

test('notify skipped when webhook URL is missing', async () => {
  const env = makeEnv({
    NOTIFY_WEBHOOK_URL: '',
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'notify', params: { body: 'hello' } }],
    }),
  });
  const fetchCalls = [];
  const fetch = async (url) => { fetchCalls.push(url); return { ok: true }; };

  await executeIssuePlan({ github: makeGithub(), context: makeContext(), env, fetchFn: fetch });

  assert.equal(fetchCalls.length, 0);
});

test('notify calls webhook with correct payload', async () => {
  const requests = [];
  const fetchFn = async (url, opts) => {
    requests.push({ url, body: JSON.parse(opts.body) });
    return { ok: true };
  };
  const env = makeEnv({
    NOTIFY_WEBHOOK_URL: 'https://hooks.example.com/test',
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'notify', params: { body: 'deploy done', channel: '#alerts' } }],
    }),
  });

  await executeIssuePlan({ github: makeGithub(), context: makeContext(), env, fetchFn });

  assert.equal(requests[0].url, 'https://hooks.example.com/test');
  assert.equal(requests[0].body.text, 'deploy done');
  assert.equal(requests[0].body.channel, '#alerts');
});

test('link_linear skipped when token is missing', async () => {
  const fetchCalls = [];
  const env = makeEnv({
    LINEAR_TOKEN: '',
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'link_linear', params: { linear_issue_id: 'ENG-42' } }],
    }),
  });

  await executeIssuePlan({ github: makeGithub(), context: makeContext(), env, fetchFn: async () => fetchCalls.push(1) });

  assert.equal(fetchCalls.length, 0);
});

test('dispatch_mcp_task throws when task not in registry', async () => {
  const env = makeEnv({
    WORKSPACE_PATH: '/tmp/nonexistent-workspace',
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'dispatch_mcp_task', params: { task: 'unknown-task' } }],
    }),
  });
  await assert.rejects(
    () => executeIssuePlan({ github: makeGithub(), context: makeContext(), env, fetchFn: okFetch() }),
    /not declared/,
  );
});

test('issue mutations require issue number', async () => {
  const env = makeEnv({
    ISSUE_NUMBER: '',
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'add_label', params: { labels: ['bug'] } }],
    }),
  });
  await assert.rejects(
    () => executeIssuePlan({ github: makeGithub(), context: makeContext(), env, fetchFn: okFetch() }),
    /no issue number is available/,
  );
});

test('escalate defaults to needs-human label', async () => {
  const labels = [];
  const github = makeGithub({
    issues: { addLabels: async (args) => labels.push(...args.labels) },
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'escalate', params: {} }],
    }),
  });

  await executeIssuePlan({ github, context: makeContext(), env, fetchFn: okFetch() });

  assert.ok(labels.includes('needs-human'));
});
