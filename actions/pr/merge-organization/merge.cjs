// Deterministic metadata-only gate, following trade's verified-head merge policy.
const REQUIRED = {
  leader: ['Moved control records stay frozen', 'Python 3.14 tests, lint and types', 'Web typecheck and build'],
  zhituo: ['Workflow checks', 'Build and release'],
};
const GOOD = new Set(['success', 'neutral', 'skipped']);
function latestChecks(checks) {
  const latest = new Map();
  for (const c of checks) {
    const key = `${c.app?.slug}:${c.name}`;
    if (!latest.has(key) || latest.get(key).id < c.id) latest.set(key, c);
  }
  return [...latest.values()];
}
function blockers(p, f, required) {
  const reasons = [];
  if (p.state !== 'open' || p.draft || p.mergeable !== true) reasons.push('draft, closed, conflict or mergeability unknown');
  if (p.head?.repo?.full_name !== p.base?.repo?.full_name) reasons.push('fork head requires review');
  if (p.labels?.some(x => ['do-not-merge', 'hold', 'blocked', 'wip'].includes(x.name.toLowerCase()))) reasons.push('hold label');
  const checks = latestChecks(f.checks).filter(c => c.app?.slug !== 'mergify');
  if (!checks.some(c => c.app?.slug === 'github-actions' && c.status === 'completed' && c.conclusion === 'success')) reasons.push('no successful CI check');
  for (const c of checks) if (c.status !== 'completed' || !GOOD.has(c.conclusion)) reasons.push(`check ${c.name}: ${c.conclusion || c.status}`);
  for (const r of required) if (!checks.some(c => c.name === r.name && c.app?.slug === r.app && c.conclusion === 'success')) reasons.push(`required ${r.name} missing`);
  const statuses = new Map();
  for (const s of f.statuses) if (!statuses.has(s.context)) statuses.set(s.context, s);
  for (const s of statuses.values()) if (s.state !== 'success') reasons.push(`status ${s.context}: ${s.state}`);
  const runs = new Map();
  for (const r of f.runs.filter(r => ['pull_request', 'push'].includes(r.event))) {
    const key = `${r.workflow_id}:${r.event}`;
    if (!runs.has(key) || runs.get(key).id < r.id) runs.set(key, r);
  }
  for (const r of runs.values()) if (r.status !== 'completed' || !GOOD.has(r.conclusion)) reasons.push(`workflow ${r.name || r.workflow_id}: ${r.conclusion || r.status}`);
  const reviews = new Map();
  for (const r of f.reviews) if (['APPROVED', 'CHANGES_REQUESTED', 'DISMISSED'].includes(r.state)) reviews.set(r.user.login, r.state);
  if ([...reviews.values()].includes('CHANGES_REQUESTED')) reasons.push('changes requested');
  if (f.unresolved) reasons.push(`${f.unresolved} unresolved review threads`);
  return reasons;
}
async function mergeOne(github, repository, pull, dryRun) {
  const [owner, repo] = repository.split('/');
  if (dryRun) return { repository, pr: pull.number, eligible: true, merged: false };
  let error;
  try {
    const result = await github.rest.pulls.merge({ owner, repo, pull_number: pull.number,
      sha: pull.head.sha, merge_method: repo === 'leader' ? 'merge' : 'squash' });
    if (!result.data.merged) error = new Error('merge rejected');
  } catch (e) { error = e; }
  // Read back even on an uncertain PUT. Never replay the mutation.
  const { data: back } = await github.rest.pulls.get({ owner, repo, pull_number: pull.number });
  if (!back.merged) throw new Error(`merge outcome unknown or rejected: ${repository}#${pull.number}: ${error?.message || 'not merged'}`);
  return { repository, pr: pull.number, merged: true, sha: back.merge_commit_sha };
}
async function threads(github, owner, repo, number) {
  let after = null, count = 0;
  do {
    const result = await github.graphql(`query($owner:String!,$repo:String!,$number:Int!,$after:String){
      repository(owner:$owner,name:$repo){pullRequest(number:$number){reviewThreads(first:100,after:$after){
        nodes{isResolved} pageInfo{hasNextPage endCursor}}}}}`, { owner, repo, number, after });
    const page = result.repository.pullRequest.reviewThreads;
    count += page.nodes.filter(t => !t.isResolved).length;
    after = page.pageInfo.hasNextPage ? page.pageInfo.endCursor : null;
    if (page.pageInfo.hasNextPage && !after) throw new Error('incomplete review pagination');
  } while (after);
  return count;
}
async function sweep({ github, core, dryRun = true }) {
  const repos = await github.paginate(github.rest.repos.listForOrg, { org: 'YiAgent', per_page: 100 });
  const results = [];
  for (const repository of repos) {
    if (repository.archived || repository.disabled || repository.name === 'trade') continue;
    const owner = 'YiAgent', repo = repository.name;
    const pulls = await github.paginate(github.rest.pulls.list, { owner, repo, state: 'open', base: repository.default_branch, per_page: 100 });
    for (const p of pulls.filter(p => !p.draft)) {
      try {
        const { data: pull } = await github.rest.pulls.get({ owner, repo, pull_number: p.number });
        if (Date.now() - Date.parse(pull.updated_at) < 60000) {
          results.push({ repository: repository.full_name, pr: p.number, merged: false, reasons: ['waiting for checks to register'] }); continue;
        }
        const sha = pull.head.sha;
        const [checks, statuses, runs, reviews, unresolved] = await Promise.all([
          github.paginate(github.rest.checks.listForRef, { owner, repo, ref: sha, per_page: 100 }),
          github.paginate(github.rest.repos.listCommitStatusesForRef, { owner, repo, ref: sha, per_page: 100 }),
          github.paginate(github.rest.actions.listWorkflowRunsForRepo, { owner, repo, head_sha: sha, per_page: 100 }),
          github.paginate(github.rest.pulls.listReviews, { owner, repo, pull_number: p.number, per_page: 100 }),
          threads(github, owner, repo, p.number),
        ]);
        const required = (REQUIRED[repo] || []).map(name => ({ name, app: 'github-actions' }));
        if (REQUIRED[repo]) required.push({ name: 'GitGuardian Security Checks', app: 'gitguardian' });
        const reasons = blockers(pull, { checks, statuses, runs, reviews, unresolved }, required);
        if (reasons.length) results.push({ repository: repository.full_name, pr: p.number, merged: false, reasons });
        else results.push(await mergeOne(github, repository.full_name, pull, dryRun));
      } catch (error) {
        // Auth/read failures and uncertain writes stop this repository's lane.
        core.error(`${repository.full_name}#${p.number}: ${error.message}`);
        results.push({ repository: repository.full_name, pr: p.number, error: error.message });
        break;
      }
    }
  }
  for (const r of results) core.info(JSON.stringify(r));
  await core.summary.addHeading(dryRun ? 'YiAgent PR scan (read only)' : 'YiAgent PR merge scan')
    .addCodeBlock(JSON.stringify(results, null, 2), 'json').write();
  if (results.some(r => r.error)) core.setFailed('One or more repositories could not be verified; see scan summary');
  return results;
}
module.exports = { blockers, latestChecks, mergeOne, sweep };
