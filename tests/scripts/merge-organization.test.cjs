const { test } = require('node:test');
const assert = require('node:assert/strict');
const { blockers, latestChecks, mergeOne } = require('../../actions/pr/merge-organization/merge.cjs');

const pull = () => ({ number: 1, state: 'open', draft: false, mergeable: true,
  head: { sha: 'head', repo: { full_name: 'YiAgent/example' } },
  base: { ref: 'main', repo: { full_name: 'YiAgent/example' } }, labels: [] });
const check = (name, conclusion = 'success', id = 1, app = 'github-actions') =>
  ({ id, name, status: 'completed', conclusion, app: { slug: app } });
const facts = () => ({ checks: [check('tests')], statuses: [], runs: [], reviews: [], unresolved: 0 });

test('ready PR passes; drafts, conflicts and fork heads stay open', () => {
  assert.deepEqual(blockers(pull(), facts(), []), []);
  for (const override of [{ draft: true }, { mergeable: false }, { mergeable: null },
    { head: { sha: 'head', repo: { full_name: 'outside/example' } } }]) {
    assert.ok(blockers({ ...pull(), ...override }, facts(), []).length);
  }
});
test('missing, failed and pending checks block; skipped jobs do not', () => {
  assert.ok(blockers(pull(), { ...facts(), checks: [] }, []).length);
  for (const conclusion of ['failure', 'cancelled', null]) {
    assert.ok(blockers(pull(), { ...facts(), checks: [check('tests', conclusion)] }, []).length);
  }
  assert.deepEqual(blockers(pull(), { ...facts(), checks: [check('tests'), check('irrelevant', 'skipped')] }, []), []);
});
test('required checks need success from the configured app; newest result wins', () => {
  const required = [{ name: 'tests', app: 'github-actions' }];
  assert.ok(blockers(pull(), { ...facts(), checks: [check('tests', 'success', 2, 'other')] }, required).length);
  assert.ok(blockers(pull(), { ...facts(), checks: [check('tests'), check('tests', 'failure', 2)] }, required).length);
  assert.equal(latestChecks([check('tests', 'failure', 1), check('tests', 'success', 2)])[0].id, 2);
});
test('only Mergify app checks are retired; unrelated Summary failures block', () => {
  assert.deepEqual(blockers(pull(), { ...facts(), checks: [check('tests'), check('Summary', 'failure', 2, 'mergify')] }, []), []);
  assert.ok(blockers(pull(), { ...facts(), checks: [check('tests'), check('Summary', 'failure', 2)] }, []).length);
});
test('review changes, unresolved threads, hold labels and pending workflow runs block', () => {
  for (const extra of [{ unresolved: 1 }, { reviews: [{ id: 1, state: 'CHANGES_REQUESTED', user: { login: 'reviewer' } }] },
    { runs: [{ id: 1, workflow_id: 1, event: 'pull_request', status: 'queued', conclusion: null }] }]) {
    assert.ok(blockers(pull(), { ...facts(), ...extra }, []).length);
  }
  assert.ok(blockers({ ...pull(), labels: [{ name: 'do-not-merge' }] }, facts(), []).length);
  const reviews = [{ id: 1, state: 'CHANGES_REQUESTED', user: { login: 'reviewer' } },
    { id: 2, state: 'COMMENTED', user: { login: 'reviewer' } }];
  assert.ok(blockers(pull(), { ...facts(), reviews }, []).length);
  reviews.push({ id: 3, state: 'APPROVED', user: { login: 'reviewer' } });
  assert.deepEqual(blockers(pull(), { ...facts(), reviews }, []), []);
});
test('manual workflow success cannot overwrite failed PR validation', () => {
  const runs = [
    { id: 1, workflow_id: 1, event: 'pull_request', status: 'completed', conclusion: 'failure' },
    { id: 2, workflow_id: 1, event: 'workflow_dispatch', status: 'completed', conclusion: 'success' },
  ];
  assert.ok(blockers(pull(), { ...facts(), runs }, []).length);
});
test('merge uses verified head and reads back; uncertain response never retries mutation', async () => {
  let calls = 0;
  const api = { rest: { pulls: {
    merge: async (args) => { calls++; assert.equal(args.sha, 'head'); return { data: { merged: true } }; },
    get: async () => ({ data: { ...pull(), merged: true, merge_commit_sha: 'merged' } }),
  } } };
  assert.equal((await mergeOne(api, 'YiAgent/example', pull(), false)).merged, true);
  assert.equal(calls, 1);
  api.rest.pulls.merge = async () => { calls++; throw new Error('timeout'); };
  assert.equal((await mergeOne(api, 'YiAgent/example', pull(), false)).merged, true);
  assert.equal(calls, 2);
  api.rest.pulls.get = async () => ({ data: pull() });
  await assert.rejects(mergeOne(api, 'YiAgent/example', pull(), false), /unknown/);
  assert.equal(calls, 3);
});
