'use strict';
// Integration tests for the issue-action-plan/v1 contract across
// pack-ingest → execute-plan boundary.
//
// These tests validate that:
// 1. The executor correctly accepts all valid plans from golden fixtures
// 2. The executor correctly rejects invalid/dangerous plans
// 3. High-risk actions require trusted actor association
//
// Run: node --test tests/integration/agent-plan-contract.test.js

const { test, describe } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const os = require('os');

const ROOT = path.resolve(__dirname, '../..');
const { executeIssuePlan } = require(path.join(ROOT, 'actions/issue/execute-plan/execute.js'));
const GOLDEN_DIR = path.join(ROOT, 'tests/agentic/fixtures/golden-plans');
const FIXTURE_DIR = path.join(ROOT, 'tests/agentic/fixtures/issues');

// ── Test harness helpers ──────────────────────────────────────────────────────

function makeGithub(overrides) {
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
  const o = overrides || {};
  return {
    rest: {
      issues: Object.assign({}, issues, o.issues || {}),
      git: Object.assign({}, git, o.git || {}),
    },
    paginate: async () => [],
  };
}

function makeContext(overrides) {
  return Object.assign({ repo: { owner: 'YiAgent', repo: 'OpenCI' }, runId: 99 }, overrides || {});
}

function makeEnv(plan, overrides) {
  return Object.assign({
    ACTION_PLAN: JSON.stringify(plan),
    PLAN_HASH: 'testhash',
    ISSUE_NUMBER: '9001',
    AUTHOR_ASSOC: 'OWNER',
    DEFAULT_BRANCH: 'main',
    WORKSPACE_PATH: '/tmp/nonexistent-workspace',
  }, overrides || {});
}

function okFetch() {
  return async () => ({ ok: true, text: async () => '', json: async () => ({}) });
}

function makeTempWorkspace(tasks) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'openci-int-'));
  const runtime = path.join(dir, 'runtime');
  fs.mkdirSync(runtime, { recursive: true });
  fs.writeFileSync(path.join(runtime, 'mcp-tasks.json'), JSON.stringify({ tasks: tasks || [] }));
  return dir;
}

// ── Golden plan acceptance ─────────────────────────────────────────────────────

describe('golden plan acceptance', () => {
  test('executor accepts valid-triage-plan from golden fixture', async () => {
    const plan = JSON.parse(
      fs.readFileSync(path.join(GOLDEN_DIR, 'valid-triage-plan.json'), 'utf8'),
    );
    await executeIssuePlan({
      github: makeGithub(),
      context: makeContext(),
      env: makeEnv(plan),
      fetchFn: okFetch(),
    });
  });

  test('executor accepts valid-security-plan from golden fixture (with escalate)', async () => {
    const plan = JSON.parse(
      fs.readFileSync(path.join(GOLDEN_DIR, 'valid-security-plan.json'), 'utf8'),
    );
    await executeIssuePlan({
      github: makeGithub(),
      context: makeContext(),
      env: makeEnv(plan),
      fetchFn: okFetch(),
    });
  });

  test('executor accepts empty actions plan (skip_reason set)', async () => {
    const plan = {
      version: 'issue-action-plan/v1',
      reasoning: 'No action needed — issue is already resolved.',
      actions: [],
      skip_reason: 'already-resolved',
    };
    await executeIssuePlan({
      github: makeGithub(),
      context: makeContext(),
      env: makeEnv(plan),
      fetchFn: okFetch(),
    });
  });
});

// ── Plan rejection ────────────────────────────────────────────────────────────

describe('invalid plan rejection', () => {
  test('executor rejects wrong version', async () => {
    const plan = {
      version: 'issue-action-plan/v0',
      reasoning: 'legacy',
      actions: [],
      skip_reason: null,
    };
    await assert.rejects(
      () => executeIssuePlan({
        github: makeGithub(),
        context: makeContext(),
        env: makeEnv(plan),
        fetchFn: okFetch(),
      }),
      /Unsupported plan version/,
    );
  });

  test('executor rejects unknown skill', async () => {
    const plan = {
      version: 'issue-action-plan/v1',
      reasoning: 'trying something forbidden',
      actions: [{ skill: 'delete_repository', params: {} }],
      skip_reason: null,
    };
    await assert.rejects(
      () => executeIssuePlan({
        github: makeGithub(),
        context: makeContext(),
        env: makeEnv(plan),
        fetchFn: okFetch(),
      }),
      /Unknown issue agent skill/,
    );
  });

  test('executor rejects plan with no issue number for issue mutations', async () => {
    const plan = {
      version: 'issue-action-plan/v1',
      reasoning: 'add a label',
      actions: [{ skill: 'add_label', params: { labels: ['bug'] } }],
      skip_reason: null,
    };
    await assert.rejects(
      () => executeIssuePlan({
        github: makeGithub(),
        context: makeContext(),
        env: makeEnv(plan, { ISSUE_NUMBER: '' }),
        fetchFn: okFetch(),
      }),
      /no issue number/,
    );
  });
});

// ── Trust-gated actions ───────────────────────────────────────────────────────
// High-risk actions (create_branch, close_issue, reopen_issue, dispatch_mcp_task)
// are silently skipped (not thrown) for untrusted actors and added to the audit log.

describe('trust-gated actions', () => {
  test('create_branch is silently skipped for untrusted actor (NONE association)', async () => {
    const plan = {
      version: 'issue-action-plan/v1',
      reasoning: 'create a fix branch',
      actions: [{ skill: 'create_branch', params: { branch: 'fix/test' } }],
      skip_reason: null,
    };
    let createRefCalled = false;
    const github = makeGithub({ git: { createRef: async () => { createRefCalled = true; } } });
    // Should not throw — untrusted actor causes a silent skip
    await executeIssuePlan({
      github,
      context: makeContext(),
      env: makeEnv(plan, { AUTHOR_ASSOC: 'NONE' }),
      fetchFn: okFetch(),
    });
    assert.ok(!createRefCalled, 'create_branch should be skipped for NONE association');
  });

  test('close_issue is silently skipped for untrusted actor', async () => {
    const plan = {
      version: 'issue-action-plan/v1',
      reasoning: 'close stale issue',
      actions: [{ skill: 'close_issue', params: { reason: 'not-planned' } }],
      skip_reason: null,
    };
    let updateCalled = false;
    const github = makeGithub({ issues: { update: async () => { updateCalled = true; } } });
    await executeIssuePlan({
      github,
      context: makeContext(),
      env: makeEnv(plan, { AUTHOR_ASSOC: 'FIRST_TIME_CONTRIBUTOR' }),
      fetchFn: okFetch(),
    });
    assert.ok(!updateCalled, 'close_issue should be skipped for untrusted actor');
  });

  test('add_label is allowed for any actor', async () => {
    const plan = {
      version: 'issue-action-plan/v1',
      reasoning: 'label the issue',
      actions: [{ skill: 'add_label', params: { labels: ['triage'] } }],
      skip_reason: null,
    };
    let labelsCalled = false;
    const github = makeGithub({
      issues: { addLabels: async () => { labelsCalled = true; } },
    });
    await executeIssuePlan({
      github,
      context: makeContext(),
      env: makeEnv(plan, { AUTHOR_ASSOC: 'NONE' }),
      fetchFn: okFetch(),
    });
    assert.ok(labelsCalled, 'add_label should be called for any actor');
  });

  test('add_comment is allowed for any actor', async () => {
    const plan = {
      version: 'issue-action-plan/v1',
      reasoning: 'acknowledge issue',
      actions: [{ skill: 'add_comment', params: { body: 'Thanks for the report!' } }],
      skip_reason: null,
    };
    let commentCalled = false;
    const github = makeGithub({
      issues: { createComment: async () => { commentCalled = true; } },
    });
    await executeIssuePlan({
      github,
      context: makeContext(),
      env: makeEnv(plan, { AUTHOR_ASSOC: 'NONE' }),
      fetchFn: okFetch(),
    });
    assert.ok(commentCalled, 'add_comment should be called for any actor');
  });
});

// ── MCP task dispatch ─────────────────────────────────────────────────────────

describe('mcp task dispatch', () => {
  test('dispatch_mcp_task reads task from workspace registry and calls GitHub dispatches', async () => {
    const tmpDir = makeTempWorkspace([
      { name: 'linear-create', event_type: 'openci-mcp-task' },
    ]);
    const plan = {
      version: 'issue-action-plan/v1',
      reasoning: 'dispatch to linear',
      actions: [{ skill: 'dispatch_mcp_task', params: { task: 'linear-create', payload: {} } }],
      skip_reason: null,
    };
    let fetchCalled = false;
    await executeIssuePlan({
      github: makeGithub(),
      context: makeContext(),
      env: makeEnv(plan, { AUTHOR_ASSOC: 'OWNER', WORKSPACE_PATH: tmpDir }),
      fetchFn: async (url) => {
        fetchCalled = true;
        // dispatch_mcp_task posts to the GitHub repository_dispatch endpoint
        assert.ok(url.includes('api.github.com') && url.includes('dispatches'),
          'should call GitHub dispatches endpoint, got: ' + url);
        return { ok: true, text: async () => '' };
      },
    });
    assert.ok(fetchCalled, 'dispatch_mcp_task should call fetch');
    fs.rmSync(tmpDir, { recursive: true });
  });

  test('dispatch_mcp_task fails for unknown task name', async () => {
    const plan = {
      version: 'issue-action-plan/v1',
      reasoning: 'dispatch unknown task',
      actions: [{ skill: 'dispatch_mcp_task', params: { task: 'nonexistent-task', payload: {} } }],
      skip_reason: null,
    };
    await assert.rejects(
      () => executeIssuePlan({
        github: makeGithub(),
        context: makeContext(),
        env: makeEnv(plan, { AUTHOR_ASSOC: 'OWNER' }),
        fetchFn: okFetch(),
      }),
      /task is not declared|task.*not found|unknown task/i,
    );
  });
});

// ── Audit trail ───────────────────────────────────────────────────────────────

describe('audit trail', () => {
  test('executor posts audit comment after executing actions', async () => {
    const plan = JSON.parse(
      fs.readFileSync(path.join(GOLDEN_DIR, 'valid-triage-plan.json'), 'utf8'),
    );
    const comments = [];
    const github = makeGithub({
      issues: {
        addLabels: async () => {},
        createComment: async (args) => { comments.push(args); },
      },
    });
    await executeIssuePlan({
      github,
      context: makeContext(),
      env: makeEnv(plan),
      fetchFn: okFetch(),
    });
    const auditComment = comments.find((c) =>
      (c.body || '').includes('openci-agent-run') ||
      (c.body || '').includes('audit') ||
      (c.body || '').includes('reasoning'),
    );
    assert.ok(auditComment, 'executor should post an audit/reasoning comment');
  });
});
