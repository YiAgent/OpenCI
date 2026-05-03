'use strict';

async function executePrPlan({ github, context, env }) {
  const plan = JSON.parse(env.ACTION_PLAN || '{"version":"pr-action-plan/v1","actions":[]}');
  if (plan.version !== 'pr-action-plan/v1') {
    throw new Error(`Unsupported plan version: ${plan.version}`);
  }

  const trusted = env.TRUSTED === 'true';
  const pr = context.payload.pull_request?.number;
  if (!pr) {
    return { skipped: true, reason: 'no pull_request in context' };
  }

  // Build and upsert sticky summary comment
  const riskIcon = { high: '🔴', medium: '🟡', low: '🟢' };
  const focusLines = (plan.reviewer_focus || []).map((f) => `- ${f}`).join('\n');
  const commentBody = [
    '## 🤖 OpenCI PR Analysis',
    '',
    plan.summary || '',
    '',
    `**Risk** ${riskIcon[plan.risk] ?? '⚪'} \`${plan.risk}\` — ${plan.risk_reason || ''}`,
    '',
    focusLines ? `**Reviewer Focus**\n${focusLines}` : '',
    '',
    `<!-- openci-pr-run:${env.RUN_ID} -->`,
  ].filter((l) => l !== undefined).join('\n');

  const existing = (
    await github.paginate(github.rest.issues.listComments, {
      ...context.repo, issue_number: pr, per_page: 100,
    })
  ).find((c) => (c.body || '').includes('<!-- openci-pr-run:'));

  if (existing) {
    await github.rest.issues.updateComment({ ...context.repo, comment_id: existing.id, body: commentBody });
  } else {
    await github.rest.issues.createComment({ ...context.repo, issue_number: pr, body: commentBody });
  }

  if (plan.skip_reason) {
    return { skipped: true, reason: plan.skip_reason };
  }

  const ALLOWED = new Set([
    'add_label', 'remove_label', 'add_reviewer',
    'request_changes', 'block_merge', 'escalate', 'assign_issue',
  ]);
  const HIGH_RISK = new Set(['request_changes', 'block_merge', 'escalate']);

  const executed = [];

  for (const action of plan.actions ?? []) {
    if (!ALLOWED.has(action.skill)) {
      continue;
    }
    if (action.confidence !== 'high') {
      continue;
    }
    if (!trusted && HIGH_RISK.has(action.skill)) {
      continue;
    }

    const p = action.params || {};

    switch (action.skill) {
      case 'add_label':
        if ((p.labels || []).length) {
          await github.rest.issues.addLabels({ ...context.repo, issue_number: pr, labels: p.labels });
          executed.push(`add_label: ${p.labels.join(', ')}`);
        }
        break;
      case 'remove_label':
        for (const name of p.labels || []) {
          try {
            await github.rest.issues.removeLabel({ ...context.repo, issue_number: pr, name });
            executed.push(`remove_label: ${name}`);
          } catch (error) {
            if (error.status !== 404) throw error;
          }
        }
        break;
      case 'add_reviewer':
        await github.rest.pulls.requestReviewers({
          ...context.repo, pull_number: pr,
          reviewers: p.reviewers || [],
          team_reviewers: p.team_reviewers || [],
        });
        executed.push('add_reviewer');
        break;
      case 'block_merge':
        await github.rest.issues.addLabels({ ...context.repo, issue_number: pr, labels: ['do-not-merge'] });
        if (p.reason) {
          await github.rest.issues.createComment({
            ...context.repo, issue_number: pr,
            body: `🚫 **Block merge**: ${p.reason}\n\n<!-- openci-block-merge -->`,
          });
        }
        executed.push('block_merge');
        break;
      case 'request_changes':
        if (p.body) {
          await github.rest.pulls.createReview({
            ...context.repo, pull_number: pr, body: p.body, event: 'REQUEST_CHANGES',
          });
          executed.push('request_changes');
        }
        break;
      case 'assign_issue':
        await github.rest.issues.addAssignees({
          ...context.repo, issue_number: pr, assignees: p.assignees || [],
        });
        executed.push('assign_issue');
        break;
      case 'escalate': {
        const labels = p.labels && p.labels.length ? p.labels : ['needs-human'];
        await github.rest.issues.addLabels({ ...context.repo, issue_number: pr, labels });
        executed.push(`escalate: ${labels.join(', ')}`);
        break;
      }
    }
  }

  return { skipped: false, executed };
}

module.exports = { executePrPlan };
