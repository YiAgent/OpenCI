'use strict';
// Unit tests for actions/issue/execute-plan/execute.js
// Run with: node --test tests/actions/issue-execute-plan.test.js

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const os = require('os');
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
  return async () => ({ ok: true, text: async () => '', json: async () => ({}) });
}

function makeTaskWorkspace(tasks) {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'openci-test-'));
  const runtimeDir = path.join(tmpDir, 'runtime');
  fs.mkdirSync(runtimeDir, { recursive: true });
  fs.writeFileSync(
    path.join(runtimeDir, 'mcp-tasks.json'),
    JSON.stringify({ tasks }),
  );
  return tmpDir;
}

// ── Original Tests ───────────────────────────────────────────────────────────

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

// ── New Tests ────────────────────────────────────────────────────────────────

// 1. Multiple actions executed in sequence
test('multiple actions executed in sequence', async () => {
  const sequence = [];
  const github = makeGithub({
    issues: {
      addLabels: async (args) => sequence.push(`addLabels:${args.labels.join(',')}`),
      addAssignees: async (args) => sequence.push(`addAssignees:${args.assignees.join(',')}`),
      update: async () => sequence.push('update'),
    },
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [
        { skill: 'add_label', params: { labels: ['bug'] } },
        { skill: 'assign_issue', params: { assignees: ['alice'] } },
        { skill: 'close_issue', params: {} },
      ],
    }),
  });

  await executeIssuePlan({ github, context: makeContext(), env, fetchFn: okFetch() });

  assert.equal(sequence.length, 3);
  assert.equal(sequence[0], 'addLabels:bug');
  assert.equal(sequence[1], 'addAssignees:alice');
  assert.equal(sequence[2], 'update');
});

// 2. create_branch calls git.createRef with correct SHA
test('create_branch calls git.createRef with correct SHA', async () => {
  const refCalls = [];
  const github = makeGithub({
    git: {
      getRef: async () => ({ data: { object: { sha: 'deadbeef42' } } }),
      createRef: async (args) => refCalls.push(args),
    },
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'create_branch', params: { branch: 'fix/issue-42' } }],
    }),
  });

  await executeIssuePlan({ github, context: makeContext(), env, fetchFn: okFetch() });

  assert.equal(refCalls.length, 1);
  assert.equal(refCalls[0].ref, 'refs/heads/fix/issue-42');
  assert.equal(refCalls[0].sha, 'deadbeef42');
});

// 3. create_branch uses default branch when base not specified
test('create_branch uses default branch when base not specified', async () => {
  const getRefCalls = [];
  const github = makeGithub({
    git: {
      getRef: async (args) => { getRefCalls.push(args); return { data: { object: { sha: 'abc' } } }; },
      createRef: async () => {},
    },
  });
  const env = makeEnv({
    DEFAULT_BRANCH: 'develop',
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'create_branch', params: { branch: 'feature-x' } }],
    }),
  });

  await executeIssuePlan({ github, context: makeContext(), env, fetchFn: okFetch() });

  assert.equal(getRefCalls[0].ref, 'heads/develop');
});

// 4. mark_duplicate with custom duplicate comment text
test('mark_duplicate with custom body text', async () => {
  const comments = [];
  const github = makeGithub({
    issues: {
      addLabels: async () => {},
      createComment: async (args) => comments.push(args.body),
    },
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{
        skill: 'mark_duplicate',
        params: { duplicate_of: 15, body: 'This is a duplicate, see the original discussion.' },
      }],
    }),
  });

  await executeIssuePlan({ github, context: makeContext(), env, fetchFn: okFetch() });

  assert.ok(comments[0].includes('This is a duplicate, see the original discussion.'));
  assert.ok(!comments[0].includes('Duplicate of #15'), 'should use custom body, not default');
});

// 5. set_priority with no existing priority labels (all 404)
test('set_priority with no existing priority labels succeeds', async () => {
  const added = [];
  const github = makeGithub({
    issues: {
      removeLabel: async () => { const e = new Error('not found'); e.status = 404; throw e; },
      addLabels: async (args) => added.push(...args.labels),
    },
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'set_priority', params: { priority: 'p0' } }],
    }),
  });

  await executeIssuePlan({ github, context: makeContext(), env, fetchFn: okFetch() });

  assert.ok(added.includes('priority:p0'));
});

// 6. schedule_followup with valid future due_at
test('schedule_followup with valid future due_at', async () => {
  const comments = [];
  const labels = [];
  const github = makeGithub({
    issues: {
      addLabels: async (args) => labels.push(...args.labels),
      createComment: async (args) => comments.push(args.body),
    },
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{
        skill: 'schedule_followup',
        params: { due_at: '2026-12-31T00:00:00Z', reason: 'check status' },
      }],
    }),
  });

  const audit = await executeIssuePlan({ github, context: makeContext(), env, fetchFn: okFetch() });

  assert.ok(labels.includes('followup:scheduled'));
  assert.ok(comments.some((c) => c.includes('2026-12-31')));
  assert.ok(audit.some((a) => a.startsWith('schedule_followup:')));
});

// 7. schedule_followup with exactly 90 days
test('schedule_followup with exactly 90 days succeeds', async () => {
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'schedule_followup', params: { days: 90 } }],
    }),
  });

  const audit = await executeIssuePlan({
    github: makeGithub(), context: makeContext(), env, fetchFn: okFetch(),
  });

  assert.ok(audit.some((a) => a.startsWith('schedule_followup:')));
});

// 8. link_linear when token IS set — calls GraphQL
test('link_linear with token calls Linear GraphQL twice', async () => {
  const graphQLCalls = [];
  const fetchFn = async (url, opts) => {
    const body = JSON.parse(opts.body);
    graphQLCalls.push({ url, query: body.query, variables: body.variables });
    if (body.query.includes('OpenCIIssue')) {
      return {
        ok: true,
        json: async () => ({
          data: { issue: { id: 'lin-uuid-1', identifier: 'ENG-99', url: 'https://linear.app/team/issue/ENG-99' } },
        }),
      };
    }
    return { ok: true, json: async () => ({ data: { commentCreate: { success: true } } }) };
  };
  const env = makeEnv({
    LINEAR_TOKEN: 'lin_api_test123',
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'link_linear', params: { linear_issue_id: 'ENG-99' } }],
    }),
  });

  const audit = await executeIssuePlan({
    github: makeGithub(), context: makeContext(), env, fetchFn,
  });

  assert.equal(graphQLCalls.length, 2);
  assert.equal(graphQLCalls[0].url, 'https://api.linear.app/graphql');
  assert.ok(graphQLCalls[0].query.includes('OpenCIIssue'));
  assert.equal(graphQLCalls[0].variables.id, 'ENG-99');
  assert.ok(graphQLCalls[1].query.includes('CommentCreate'));
  assert.equal(graphQLCalls[1].variables.input.issueId, 'lin-uuid-1');
  assert.ok(audit.some((a) => a.includes('ENG-99')));
});

// 9. link_linear when linear_issue_id is missing
test('link_linear throws when linear_issue_id is missing', async () => {
  const env = makeEnv({
    LINEAR_TOKEN: 'lin_api_test',
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'link_linear', params: {} }],
    }),
  });

  await assert.rejects(
    () => executeIssuePlan({ github: makeGithub(), context: makeContext(), env, fetchFn: okFetch() }),
    /link_linear requires linear_issue_id/,
  );
});

// 10. dispatch_mcp_task with valid task in registry
test('dispatch_mcp_task with valid task dispatches correctly', async () => {
  const tmpDir = makeTaskWorkspace([{ name: 'sync-labels', event_type: 'openci-sync' }]);
  const dispatchCalls = [];
  const fetchFn = async (url, opts) => {
    dispatchCalls.push({ url, body: JSON.parse(opts.body) });
    return { ok: true, text: async () => '' };
  };
  const env = makeEnv({
    WORKSPACE_PATH: tmpDir,
    MCP_DISPATCH_TOKEN: 'ghp_test_token',
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'dispatch_mcp_task', params: { task: 'sync-labels', payload: { foo: 'bar' } } }],
    }),
  });

  try {
    const audit = await executeIssuePlan({
      github: makeGithub(), context: makeContext(), env, fetchFn,
    });

    assert.equal(dispatchCalls.length, 1);
    assert.ok(dispatchCalls[0].url.includes('/dispatches'));
    assert.equal(dispatchCalls[0].body.event_type, 'openci-sync');
    assert.equal(dispatchCalls[0].body.client_payload.task, 'sync-labels');
    assert.equal(dispatchCalls[0].body.client_payload.payload.foo, 'bar');
    assert.ok(audit.some((a) => a.includes('sync-labels')));
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

// 11. notify with custom message (params.message instead of params.body)
test('notify uses params.message when params.body is absent', async () => {
  const requests = [];
  const fetchFn = async (url, opts) => {
    requests.push(JSON.parse(opts.body));
    return { ok: true };
  };
  const env = makeEnv({
    NOTIFY_WEBHOOK_URL: 'https://hooks.example.com/test',
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'notify', params: { message: 'custom alert message', channel: '#ops' } }],
    }),
  });

  await executeIssuePlan({ github: makeGithub(), context: makeContext(), env, fetchFn });

  assert.equal(requests[0].text, 'custom alert message');
  assert.equal(requests[0].channel, '#ops');
});

// 12. escalate with multiple custom labels
test('escalate with multiple custom labels', async () => {
  const labels = [];
  const github = makeGithub({
    issues: { addLabels: async (args) => labels.push(...args.labels) },
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'escalate', params: { labels: ['urgent', 'security', 'p0'] } }],
    }),
  });

  await executeIssuePlan({ github, context: makeContext(), env, fetchFn: okFetch() });

  assert.deepEqual(labels, ['urgent', 'security', 'p0']);
});

// 13. add_comment with markdown body
test('add_comment with markdown body', async () => {
  const comments = [];
  const github = makeGithub({
    issues: { createComment: async (args) => comments.push(args.body) },
  });
  const mdBody = '## Summary\n\n- Item 1\n- Item 2\n\n**Bold** and `code`';
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'add_comment', params: { body: mdBody } }],
    }),
  });

  await executeIssuePlan({ github, context: makeContext(), env, fetchFn: okFetch() });

  assert.ok(comments[0].includes('## Summary'));
  assert.ok(comments[0].includes('**Bold**'));
});

// 14. Mixed trusted and untrusted actions
test('mixed trusted and untrusted actions — high-risk blocked, low-risk execute', async () => {
  const updateCalls = [];
  const labelCalls = [];
  const github = makeGithub({
    issues: {
      update: async (args) => updateCalls.push(args),
      addLabels: async (args) => labelCalls.push(...args.labels),
    },
  });
  const env = makeEnv({
    AUTHOR_ASSOC: 'CONTRIBUTOR',
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [
        { skill: 'add_label', params: { labels: ['triage'] } },
        { skill: 'close_issue', params: {} },
        { skill: 'escalate', params: { labels: ['needs-human'] } },
        { skill: 'reopen_issue', params: {} },
      ],
    }),
  });

  const audit = await executeIssuePlan({ github, context: makeContext(), env, fetchFn: okFetch() });

  assert.ok(labelCalls.includes('triage'));
  assert.ok(labelCalls.includes('needs-human'));
  assert.equal(updateCalls.length, 0);
  assert.ok(audit.some((a) => a.includes('blocked close_issue')));
  assert.ok(audit.some((a) => a.includes('blocked reopen_issue')));
  assert.ok(audit.some((a) => a.startsWith('add_label:')));
  assert.ok(audit.some((a) => a.startsWith('escalate:')));
});

// 15. Plan with empty actions array produces no audit comment
test('empty actions array produces no audit comment', async () => {
  const comments = [];
  const github = makeGithub({
    issues: { createComment: async (args) => comments.push(args.body) },
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [],
    }),
  });

  const audit = await executeIssuePlan({ github, context: makeContext(), env, fetchFn: okFetch() });

  assert.deepEqual(audit, []);
  assert.equal(comments.length, 0, 'no audit comment should be posted for empty actions');
});

// 16. Audit comment contains plan hash
test('audit comment contains plan hash', async () => {
  const comments = [];
  const github = makeGithub({
    issues: {
      addLabels: async () => {},
      createComment: async (args) => comments.push(args.body),
    },
  });
  const env = makeEnv({
    PLAN_HASH: 'sha256-abcdef1234567890',
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'add_label', params: { labels: ['bug'] } }],
    }),
  });

  await executeIssuePlan({ github, context: makeContext(), env, fetchFn: okFetch() });

  const auditComment = comments.find((c) => c.includes('<!-- openci-agent-run:'));
  assert.ok(auditComment, 'audit comment should be present');
  assert.ok(auditComment.includes('sha256-abcdef1234567890'));
});

// 17. Audit comment lists each executed action
test('audit comment lists each executed action', async () => {
  const comments = [];
  const github = makeGithub({
    issues: {
      addLabels: async () => {},
      addAssignees: async () => {},
      createComment: async (args) => comments.push(args.body),
    },
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [
        { skill: 'add_label', params: { labels: ['bug'] } },
        { skill: 'assign_issue', params: { assignees: ['bob'] } },
      ],
    }),
  });

  await executeIssuePlan({ github, context: makeContext(), env, fetchFn: okFetch() });

  const auditComment = comments.find((c) => c.includes('<!-- openci-agent-run:'));
  assert.ok(auditComment);
  const bulletLines = auditComment.split('\n').filter((l) => l.startsWith('- '));
  assert.equal(bulletLines.length, 2);
});

// 18. All 14 skills individually — reopen_issue
test('reopen_issue calls update with state open', async () => {
  const calls = [];
  const github = makeGithub({
    issues: { update: async (args) => calls.push(args) },
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'reopen_issue', params: {} }],
    }),
  });

  await executeIssuePlan({ github, context: makeContext(), env, fetchFn: okFetch() });

  assert.equal(calls[0].state, 'open');
});

// 18. All 14 skills individually — assign_issue
test('assign_issue calls addAssignees with correct args', async () => {
  const calls = [];
  const github = makeGithub({
    issues: { addAssignees: async (args) => calls.push(args) },
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'assign_issue', params: { assignees: ['alice', 'bob'] } }],
    }),
  });

  await executeIssuePlan({ github, context: makeContext(), env, fetchFn: okFetch() });

  assert.deepEqual(calls[0].assignees, ['alice', 'bob']);
  assert.equal(calls[0].issue_number, 42);
});

test('assign_issue supports singular assignee param', async () => {
  const calls = [];
  const github = makeGithub({
    issues: { addAssignees: async (args) => calls.push(args) },
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'assign_issue', params: { assignee: 'charlie' } }],
    }),
  });

  await executeIssuePlan({ github, context: makeContext(), env, fetchFn: okFetch() });

  assert.deepEqual(calls[0].assignees, ['charlie']);
});

// 18. All 14 skills individually — create_branch handles 422
test('create_branch handles 422 (branch exists) gracefully', async () => {
  const github = makeGithub({
    git: {
      getRef: async () => ({ data: { object: { sha: 'abc' } } }),
      createRef: async () => { const e = new Error('Reference already exists'); e.status = 422; throw e; },
    },
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'create_branch', params: { branch: 'main' } }],
    }),
  });

  const audit = await executeIssuePlan({ github, context: makeContext(), env, fetchFn: okFetch() });

  assert.ok(audit.some((a) => a.includes('skipped')));
});

// 18. All 14 skills individually — remove_label removes each label
test('remove_label removes each label individually', async () => {
  const removed = [];
  const github = makeGithub({
    issues: { removeLabel: async (args) => removed.push(args.name) },
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'remove_label', params: { labels: ['stale', 'wontfix'] } }],
    }),
  });

  await executeIssuePlan({ github, context: makeContext(), env, fetchFn: okFetch() });

  assert.deepEqual(removed, ['stale', 'wontfix']);
});

// 18. All 14 skills individually — close_issue default reason
test('close_issue with explicit completed reason', async () => {
  const calls = [];
  const github = makeGithub({
    issues: { update: async (args) => calls.push(args) },
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'close_issue', params: { reason: 'completed' } }],
    }),
  });

  await executeIssuePlan({ github, context: makeContext(), env, fetchFn: okFetch() });

  assert.equal(calls[0].state_reason, 'completed');
});

// 18. All 14 skills individually — mark_duplicate uses duplicateOf alias
test('mark_duplicate uses duplicateOf alias', async () => {
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
      actions: [{ skill: 'mark_duplicate', params: { duplicateOf: 23 } }],
    }),
  });

  await executeIssuePlan({ github, context: makeContext(), env, fetchFn: okFetch() });

  assert.ok(labels.includes('duplicate'));
  assert.ok(comments[0].includes('#23'));
});

// 18. All 14 skills individually — set_priority with labels param fallback
test('set_priority with labels param fallback', async () => {
  const added = [];
  const github = makeGithub({
    issues: {
      removeLabel: async () => { const e = new Error('not found'); e.status = 404; throw e; },
      addLabels: async (args) => added.push(...args.labels),
    },
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'set_priority', params: { labels: ['priority:p3'] } }],
    }),
  });

  await executeIssuePlan({ github, context: makeContext(), env, fetchFn: okFetch() });

  assert.ok(added.includes('priority:p3'));
});

// 18. All 14 skills individually — schedule_followup uses delay_days alias
test('schedule_followup uses delay_days alias', async () => {
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'schedule_followup', params: { delay_days: 7 } }],
    }),
  });

  const audit = await executeIssuePlan({
    github: makeGithub(), context: makeContext(), env, fetchFn: okFetch(),
  });

  assert.ok(audit.some((a) => a.startsWith('schedule_followup:')));
});

// 18. All 14 skills individually — schedule_followup uses params.body as reason fallback
test('schedule_followup uses params.body as reason fallback', async () => {
  const comments = [];
  const github = makeGithub({
    issues: {
      addLabels: async () => {},
      createComment: async (args) => comments.push(args.body),
    },
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'schedule_followup', params: { days: 1, body: 'Check if fixed.' } }],
    }),
  });

  await executeIssuePlan({ github, context: makeContext(), env, fetchFn: okFetch() });

  const followupComment = comments.find((c) => c.includes('openci-followup'));
  assert.ok(followupComment);
  assert.ok(followupComment.includes('Check if fixed.'));
});

// 18. All 14 skills individually — dispatch_mcp_task uses task.event_type fallback
test('dispatch_mcp_task uses task.event_type fallback', async () => {
  const tmpDir = makeTaskWorkspace([{ name: 'gen-report', event_type: 'custom-dispatch' }]);
  const dispatchCalls = [];
  const fetchFn = async (url, opts) => {
    dispatchCalls.push(JSON.parse(opts.body));
    return { ok: true, text: async () => '' };
  };
  const env = makeEnv({
    WORKSPACE_PATH: tmpDir,
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'dispatch_mcp_task', params: { task: 'gen-report' } }],
    }),
  });

  try {
    await executeIssuePlan({ github: makeGithub(), context: makeContext(), env, fetchFn });

    assert.equal(dispatchCalls[0].event_type, 'custom-dispatch');
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

// 18. All 14 skills individually — dispatch_mcp_task uses params.name alias
test('dispatch_mcp_task uses params.name alias', async () => {
  const tmpDir = makeTaskWorkspace([{ name: 'my-task' }]);
  const dispatchCalls = [];
  const fetchFn = async (url, opts) => {
    dispatchCalls.push(JSON.parse(opts.body));
    return { ok: true, text: async () => '' };
  };
  const env = makeEnv({
    WORKSPACE_PATH: tmpDir,
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'dispatch_mcp_task', params: { name: 'my-task' } }],
    }),
  });

  try {
    await executeIssuePlan({ github: makeGithub(), context: makeContext(), env, fetchFn });

    assert.equal(dispatchCalls[0].client_payload.task, 'my-task');
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

// 18. All 14 skills individually — notify uses default message
test('notify uses default message when body and message are absent', async () => {
  const requests = [];
  const fetchFn = async (url, opts) => {
    requests.push(JSON.parse(opts.body));
    return { ok: true };
  };
  const env = makeEnv({
    NOTIFY_WEBHOOK_URL: 'https://hooks.example.com/test',
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'notify', params: {} }],
    }),
  });

  await executeIssuePlan({ github: makeGithub(), context: makeContext(), env, fetchFn });

  assert.ok(requests[0].text.includes('notification'));
  assert.ok(requests[0].text.includes('issues/42'));
});

// 18. All 14 skills individually — link_linear uses issue_id alias
test('link_linear uses issue_id alias', async () => {
  const graphQLCalls = [];
  const fetchFn = async (url, opts) => {
    const body = JSON.parse(opts.body);
    graphQLCalls.push(body);
    if (body.query.includes('OpenCIIssue')) {
      return { ok: true, json: async () => ({ data: { issue: { id: 'uuid-1', identifier: 'PROJ-1' } } }) };
    }
    return { ok: true, json: async () => ({ data: { commentCreate: { success: true } } }) };
  };
  const env = makeEnv({
    LINEAR_TOKEN: 'lin_api_key',
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'link_linear', params: { issue_id: 'PROJ-1' } }],
    }),
  });

  const audit = await executeIssuePlan({
    github: makeGithub(), context: makeContext(), env, fetchFn,
  });

  assert.ok(audit.some((a) => a.includes('PROJ-1')));
});

// 18. All 14 skills individually — link_linear uses identifier alias
test('link_linear uses identifier alias', async () => {
  const fetchFn = async (url, opts) => {
    const body = JSON.parse(opts.body);
    if (body.query.includes('OpenCIIssue')) {
      return { ok: true, json: async () => ({ data: { issue: { id: 'uuid-2', identifier: 'ENG-7' } } }) };
    }
    return { ok: true, json: async () => ({ data: { commentCreate: { success: true } } }) };
  };
  const env = makeEnv({
    LINEAR_TOKEN: 'lin_api_key',
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'link_linear', params: { identifier: 'ENG-7' } }],
    }),
  });

  const audit = await executeIssuePlan({
    github: makeGithub(), context: makeContext(), env, fetchFn,
  });

  assert.ok(audit.some((a) => a.includes('ENG-7')));
});

// 19. Unknown skill in middle of valid skills throws and stops execution
test('unknown skill in middle of valid skills throws and stops execution', async () => {
  const labelCalls = [];
  const updateCalls = [];
  const github = makeGithub({
    issues: {
      addLabels: async (args) => labelCalls.push(...args.labels),
      update: async (args) => updateCalls.push(args),
    },
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [
        { skill: 'add_label', params: { labels: ['first'] } },
        { skill: 'nonexistent_skill', params: {} },
        { skill: 'close_issue', params: {} },
      ],
    }),
  });

  await assert.rejects(
    () => executeIssuePlan({ github, context: makeContext(), env, fetchFn: okFetch() }),
    /Unknown issue agent skill: nonexistent_skill/,
  );

  assert.ok(labelCalls.includes('first'), 'first action executed before throw');
  assert.equal(updateCalls.length, 0, 'third action never reached');
});

// 20. add_label with empty labels array is no-op
test('add_label with empty labels array is no-op', async () => {
  const calls = [];
  const github = makeGithub({
    issues: { addLabels: async (args) => calls.push(args) },
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'add_label', params: { labels: [] } }],
    }),
  });

  await executeIssuePlan({ github, context: makeContext(), env, fetchFn: okFetch() });

  assert.equal(calls.length, 0, 'addLabels should not be called for empty labels array');
});

// ── Additional Edge Cases ────────────────────────────────────────────────────

test('audit comment deduplication — skips if marker already exists', async () => {
  const comments = [];
  const github = makeGithub({
    issues: {
      addLabels: async () => {},
      createComment: async (args) => comments.push(args.body),
    },
  });
  github.paginate = async () => [{ body: '<!-- openci-agent-run: 99:testhash -->' }];
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'add_label', params: { labels: ['bug'] } }],
    }),
  });

  await executeIssuePlan({ github, context: makeContext(), env, fetchFn: okFetch() });

  assert.equal(comments.length, 0, 'audit comment should be skipped when marker already exists');
});

test('audit comment includes reasoning from env', async () => {
  const comments = [];
  const github = makeGithub({
    issues: {
      addLabels: async () => {},
      createComment: async (args) => comments.push(args.body),
    },
  });
  const env = makeEnv({
    REASONING: 'Closed because the issue was resolved in PR #10.',
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'add_label', params: { labels: ['resolved'] } }],
    }),
  });

  await executeIssuePlan({ github, context: makeContext(), env, fetchFn: okFetch() });

  const auditComment = comments.find((c) => c.includes('<!-- openci-agent-run:'));
  assert.ok(auditComment.includes('Closed because the issue was resolved in PR #10.'));
});

test('audit comment includes reasoning from plan fallback', async () => {
  const comments = [];
  const github = makeGithub({
    issues: {
      addLabels: async () => {},
      createComment: async (args) => comments.push(args.body),
    },
  });
  const env = makeEnv({
    REASONING: '',
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'add_label', params: { labels: ['bug'] } }],
      reasoning: 'Plan-level reasoning fallback',
    }),
  });

  await executeIssuePlan({ github, context: makeContext(), env, fetchFn: okFetch() });

  const auditComment = comments.find((c) => c.includes('<!-- openci-agent-run:'));
  assert.ok(auditComment.includes('Plan-level reasoning fallback'));
});

test('dispatch_mcp_task without MCP_DISPATCH_TOKEN sends empty bearer', async () => {
  const tmpDir = makeTaskWorkspace([{ name: 'task-x' }]);
  let capturedHeaders;
  const fetchFn = async (url, opts) => {
    capturedHeaders = opts.headers;
    return { ok: true, text: async () => '' };
  };
  const env = makeEnv({
    WORKSPACE_PATH: tmpDir,
    MCP_DISPATCH_TOKEN: '',
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'dispatch_mcp_task', params: { task: 'task-x' } }],
    }),
  });

  try {
    await executeIssuePlan({ github: makeGithub(), context: makeContext(), env, fetchFn });
    assert.ok(!('authorization' in capturedHeaders), 'no authorization header when token is empty');
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test('schedule_followup rejects days > 90', async () => {
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'schedule_followup', params: { days: 91 } }],
    }),
  });

  await assert.rejects(
    () => executeIssuePlan({ github: makeGithub(), context: makeContext(), env, fetchFn: okFetch() }),
    /schedule_followup requires due_at or days/,
  );
});

test('notify throws when webhook returns non-ok', async () => {
  const fetchFn = async () => ({ ok: false, text: async () => 'service unavailable' });
  const env = makeEnv({
    NOTIFY_WEBHOOK_URL: 'https://hooks.example.com/fail',
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'notify', params: { body: 'test' } }],
    }),
  });

  await assert.rejects(
    () => executeIssuePlan({ github: makeGithub(), context: makeContext(), env, fetchFn }),
    /notify webhook failed/,
  );
});

test('link_linear throws when Linear API returns errors', async () => {
  const fetchFn = async () => ({
    ok: true,
    json: async () => ({ errors: [{ message: 'Issue not found' }] }),
  });
  const env = makeEnv({
    LINEAR_TOKEN: 'lin_api_key',
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'link_linear', params: { linear_issue_id: 'BAD-1' } }],
    }),
  });

  await assert.rejects(
    () => executeIssuePlan({ github: makeGithub(), context: makeContext(), env, fetchFn }),
    /Linear GraphQL request failed/,
  );
});

test('no issue number allows no-issue skills (notify)', async () => {
  const fetchCalls = [];
  const env = makeEnv({
    ISSUE_NUMBER: '',
    NOTIFY_WEBHOOK_URL: 'https://hooks.example.com/test',
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'notify', params: { body: 'hello' } }],
    }),
  });

  const audit = await executeIssuePlan({
    github: makeGithub(),
    context: makeContext(),
    env,
    fetchFn: async (url) => { fetchCalls.push(url); return { ok: true }; },
  });

  assert.ok(fetchCalls.length > 0);
  assert.ok(audit.some((a) => a.startsWith('notify:')));
});

test('no issue number allows no-issue skills (escalate without issue)', async () => {
  const env = makeEnv({
    ISSUE_NUMBER: '',
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'escalate', params: { labels: ['urgent'] } }],
    }),
  });

  // escalate requires issueNumber to add labels, so it silently skips
  const audit = await executeIssuePlan({
    github: makeGithub(), context: makeContext(), env, fetchFn: okFetch(),
  });

  assert.equal(audit.length, 0, 'escalate without issue number produces no audit');
});

test('all 14 allowed skills are recognized', async () => {
  const allSkills = [
    'add_label', 'remove_label', 'set_priority', 'assign_issue',
    'add_comment', 'close_issue', 'reopen_issue', 'mark_duplicate',
    'create_branch', 'link_linear', 'dispatch_mcp_task',
    'schedule_followup', 'notify', 'escalate',
  ];

  for (const skill of allSkills) {
    const params = {};
    if (skill === 'add_label' || skill === 'remove_label') params.labels = ['x'];
    if (skill === 'set_priority') params.priority = 'p1';
    if (skill === 'assign_issue') params.assignees = ['a'];
    if (skill === 'add_comment') params.body = 'x';
    if (skill === 'mark_duplicate') params.duplicate_of = 1;
    if (skill === 'create_branch') params.branch = 'test-branch';
    if (skill === 'link_linear') params.linear_issue_id = 'X-1';
    if (skill === 'dispatch_mcp_task') params.task = 'registered';
    if (skill === 'schedule_followup') params.days = 1;
    if (skill === 'notify') params.body = 'x';

    const extraEnv = {};
    let tmpDir;
    if (skill === 'link_linear') extraEnv.LINEAR_TOKEN = 'token';
    if (skill === 'dispatch_mcp_task') {
      tmpDir = makeTaskWorkspace([{ name: 'registered' }]);
      extraEnv.WORKSPACE_PATH = tmpDir;
    }

    const fetchFn = async (url, opts) => {
      if (url === 'https://api.linear.app/graphql') {
        return {
          ok: true,
          json: async () => ({
            data: { issue: { id: '1', identifier: 'X-1' }, commentCreate: { success: true } },
          }),
        };
      }
      return { ok: true, text: async () => '' };
    };

    const env = makeEnv({
      ...extraEnv,
      ACTION_PLAN: JSON.stringify({
        version: 'issue-action-plan/v1',
        actions: [{ skill, params }],
      }),
    });

    try {
      await assert.doesNotReject(
        () => executeIssuePlan({ github: makeGithub(), context: makeContext(), env, fetchFn }),
        `${skill} should be recognized as a valid skill`,
      );
    } finally {
      if (tmpDir) fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  }
});

test('set_priority with invalid priority (not p0-p3) is no-op', async () => {
  const added = [];
  const removed = [];
  const github = makeGithub({
    issues: {
      removeLabel: async (args) => removed.push(args.name),
      addLabels: async (args) => added.push(...args.labels),
    },
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'set_priority', params: { priority: 'p99' } }],
    }),
  });

  await executeIssuePlan({ github, context: makeContext(), env, fetchFn: okFetch() });

  assert.equal(removed.length, 0);
  assert.equal(added.length, 0);
});

test('create_branch with no branch param is no-op', async () => {
  const refCalls = [];
  const github = makeGithub({
    git: {
      getRef: async () => ({ data: { object: { sha: 'abc' } } }),
      createRef: async (args) => refCalls.push(args),
    },
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'create_branch', params: {} }],
    }),
  });

  await executeIssuePlan({ github, context: makeContext(), env, fetchFn: okFetch() });

  assert.equal(refCalls.length, 0);
});

test('mark_duplicate with no duplicate_of is no-op', async () => {
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
      actions: [{ skill: 'mark_duplicate', params: {} }],
    }),
  });

  await executeIssuePlan({ github, context: makeContext(), env, fetchFn: okFetch() });

  assert.equal(labels.length, 0);
  assert.equal(comments.length, 0);
});

test('dispatch_mcp_task uses default event_type when not in task or params', async () => {
  const tmpDir = makeTaskWorkspace([{ name: 'bare-task' }]);
  const dispatchCalls = [];
  const fetchFn = async (url, opts) => {
    dispatchCalls.push(JSON.parse(opts.body));
    return { ok: true, text: async () => '' };
  };
  const env = makeEnv({
    WORKSPACE_PATH: tmpDir,
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'dispatch_mcp_task', params: { task: 'bare-task' } }],
    }),
  });

  try {
    await executeIssuePlan({ github: makeGithub(), context: makeContext(), env, fetchFn });

    assert.equal(dispatchCalls[0].event_type, 'openci-mcp-task');
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test('audit comment marker includes PLAN_HASH', async () => {
  const comments = [];
  const github = makeGithub({
    issues: {
      addLabels: async () => {},
      createComment: async (args) => comments.push(args.body),
    },
  });
  const env = makeEnv({
    PLAN_HASH: 'abc999',
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'add_label', params: { labels: ['x'] } }],
    }),
  });

  await executeIssuePlan({ github, context: makeContext({ runId: 42 }), env, fetchFn: okFetch() });

  const auditComment = comments.find((c) => c.includes('<!-- openci-agent-run:'));
  assert.ok(auditComment.includes('abc999'), 'audit comment should include PLAN_HASH value');
});

test('PLAN_HASH missing — audit comment still produced', async () => {
  const comments = [];
  const github = makeGithub({
    issues: {
      addLabels: async () => {},
      createComment: async (args) => comments.push(args.body),
    },
  });
  const env = makeEnv({
    PLAN_HASH: undefined,
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'add_label', params: { labels: ['x'] } }],
    }),
  });

  await executeIssuePlan({ github, context: makeContext(), env, fetchFn: okFetch() });

  const auditComment = comments.find((c) => c.includes('<!-- openci-agent-run:'));
  assert.ok(auditComment, 'audit comment should still be produced without PLAN_HASH');
});

test('no issue number with only no-issue skills does not throw', async () => {
  const tmpDir = makeTaskWorkspace([{ name: 't' }]);
  const env = makeEnv({
    ISSUE_NUMBER: '',
    WORKSPACE_PATH: tmpDir,
    LINEAR_TOKEN: 'tok',
    NOTIFY_WEBHOOK_URL: 'https://hooks.example.com/h',
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [
        { skill: 'create_branch', params: { branch: 'b' } },
        { skill: 'notify', params: { body: 'n' } },
        { skill: 'escalate', params: {} },
      ],
    }),
  });

  try {
    await assert.doesNotReject(
      () => executeIssuePlan({
        github: makeGithub(),
        context: makeContext(),
        env,
        fetchFn: async () => ({ ok: true, text: async () => '', json: async () => ({}) }),
      }),
    );
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});

test('empty params object defaults gracefully for add_label', async () => {
  const calls = [];
  const github = makeGithub({
    issues: { addLabels: async (args) => calls.push(args) },
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'add_label', params: {} }],
    }),
  });

  await executeIssuePlan({ github, context: makeContext(), env, fetchFn: okFetch() });

  assert.equal(calls.length, 0, 'no labels to add when params is empty');
});

test('missing params object defaults gracefully', async () => {
  const calls = [];
  const github = makeGithub({
    issues: { addLabels: async (args) => calls.push(args) },
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'add_label' }],
    }),
  });

  await executeIssuePlan({ github, context: makeContext(), env, fetchFn: okFetch() });

  assert.equal(calls.length, 0);
});

test('remove_label with non-404 error rethrows', async () => {
  const github = makeGithub({
    issues: {
      removeLabel: async () => { const e = new Error('server error'); e.status = 500; throw e; },
    },
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'remove_label', params: { labels: ['x'] } }],
    }),
  });

  await assert.rejects(
    () => executeIssuePlan({ github, context: makeContext(), env, fetchFn: okFetch() }),
    /server error/,
  );
});

test('set_priority with non-404 removeLabel error rethrows', async () => {
  const github = makeGithub({
    issues: {
      removeLabel: async () => { const e = new Error('rate limited'); e.status = 403; throw e; },
      addLabels: async () => {},
    },
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'set_priority', params: { priority: 'p1' } }],
    }),
  });

  await assert.rejects(
    () => executeIssuePlan({ github, context: makeContext(), env, fetchFn: okFetch() }),
    /rate limited/,
  );
});

test('create_branch with non-422 error rethrows', async () => {
  const github = makeGithub({
    git: {
      getRef: async () => ({ data: { object: { sha: 'abc' } } }),
      createRef: async () => { const e = new Error('server error'); e.status = 500; throw e; },
    },
  });
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'create_branch', params: { branch: 'x' } }],
    }),
  });

  await assert.rejects(
    () => executeIssuePlan({ github, context: makeContext(), env, fetchFn: okFetch() }),
    /server error/,
  );
});

test('dispatch_mcp_task throws when params.task and params.name are both absent', async () => {
  const env = makeEnv({
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'dispatch_mcp_task', params: {} }],
    }),
  });

  await assert.rejects(
    () => executeIssuePlan({ github: makeGithub(), context: makeContext(), env, fetchFn: okFetch() }),
    /dispatch_mcp_task requires task/,
  );
});

test('postJson dispatch throws on non-ok response', async () => {
  const tmpDir = makeTaskWorkspace([{ name: 't' }]);
  const fetchFn = async () => ({ ok: false, text: async () => 'forbidden' });
  const env = makeEnv({
    WORKSPACE_PATH: tmpDir,
    ACTION_PLAN: JSON.stringify({
      version: 'issue-action-plan/v1',
      actions: [{ skill: 'dispatch_mcp_task', params: { task: 't' } }],
    }),
  });

  try {
    await assert.rejects(
      () => executeIssuePlan({ github: makeGithub(), context: makeContext(), env, fetchFn }),
      /POST .* failed/,
    );
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
});
