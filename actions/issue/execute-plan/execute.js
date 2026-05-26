'use strict';

// Exported for unit tests. Receives injected github-script globals plus a
// fetchFn override so tests never hit real HTTP endpoints.
async function executeIssuePlan({ github, context, env, fetchFn }) {
  const doFetch = fetchFn || globalThis.fetch;

  const plan = JSON.parse(env.ACTION_PLAN || '{"version":"issue-action-plan/v1","actions":[]}');
  if (plan.version !== 'issue-action-plan/v1') {
    throw new Error(`Unsupported plan version: ${plan.version}`);
  }

  const issueNumber = Number(env.ISSUE_NUMBER || 0);
  const actorAssociation = env.AUTHOR_ASSOC || '';
  const trusted = ['OWNER', 'MEMBER', 'COLLABORATOR'].includes(actorAssociation);
  const issueUrl = issueNumber
    ? `https://github.com/${context.repo.owner}/${context.repo.repo}/issues/${issueNumber}`
    : `https://github.com/${context.repo.owner}/${context.repo.repo}`;

  const loadJson = (file, fallback) => {
    try {
      const fs = require('fs');
      return JSON.parse(fs.readFileSync(file, 'utf8'));
    } catch {
      return fallback;
    }
  };

  const workspacePath = env.WORKSPACE_PATH || 'agent-workspace';
  const taskRegistry = loadJson(`${workspacePath}/runtime/mcp-tasks.json`, { tasks: [] });
  const tasks = new Map(
    (Array.isArray(taskRegistry.tasks) ? taskRegistry.tasks : []).map((t) => [t.name, t]),
  );

  const postJson = async (url, token, body) => {
    const response = await doFetch(url, {
      method: 'POST',
      headers: {
        accept: 'application/vnd.github+json',
        'content-type': 'application/json',
        ...(token ? { authorization: `Bearer ${token}` } : {}),
        'x-github-api-version': '2022-11-28',
      },
      body: JSON.stringify(body),
    });
    if (!response.ok) {
      const text = await response.text();
      throw new Error(`POST ${url} failed: ${response.status} ${text}`);
    }
    return response;
  };

  const linearRequest = async (query, variables) => {
    const token = env.LINEAR_TOKEN || '';
    if (!token) throw new Error('LINEAR_TOKEN is not configured');
    const response = await doFetch('https://api.linear.app/graphql', {
      method: 'POST',
      headers: { authorization: token, 'content-type': 'application/json' },
      body: JSON.stringify({ query, variables }),
    });
    const payload = await response.json();
    if (!response.ok || payload.errors) {
      throw new Error(`Linear GraphQL request failed: ${JSON.stringify(payload.errors || payload)}`);
    }
    return payload.data;
  };

  const computeDueAt = (params) => {
    if (params.due_at) {
      const parsed = Date.parse(params.due_at);
      if (Number.isNaN(parsed)) throw new Error(`Invalid schedule_followup due_at: ${params.due_at}`);
      return new Date(parsed).toISOString();
    }
    const days = Number(params.days || params.delay_days || 0);
    if (!Number.isFinite(days) || days < 1 || days > 90) {
      throw new Error('schedule_followup requires due_at or days between 1 and 90');
    }
    return new Date(Date.now() + days * 24 * 60 * 60 * 1000).toISOString();
  };

  const ALLOWED = new Set([
    'add_label', 'remove_label', 'set_priority', 'assign_issue',
    'add_comment', 'close_issue', 'reopen_issue', 'mark_duplicate',
    'create_branch', 'link_linear', 'dispatch_mcp_task',
    'schedule_followup', 'notify', 'escalate',
  ]);
  const HIGH_RISK = new Set(['close_issue', 'reopen_issue', 'create_branch', 'dispatch_mcp_task']);

  const actions = Array.isArray(plan.actions) ? plan.actions : [];

  const noIssueSkills = ['create_branch', 'link_linear', 'dispatch_mcp_task', 'schedule_followup', 'notify', 'escalate'];
  if (!issueNumber && actions.some((a) => !noIssueSkills.includes(a.skill))) {
    throw new Error('Plan contains issue mutations but no issue number is available');
  }

  const audit = [];

  for (const action of actions) {
    if (!ALLOWED.has(action.skill)) {
      throw new Error(`Unknown issue agent skill: ${action.skill}`);
    }
    if (HIGH_RISK.has(action.skill) && actorAssociation && !trusted) {
      audit.push(`blocked ${action.skill}: actor association ${actorAssociation} is not trusted`);
      continue;
    }

    const params = action.params || {};

    switch (action.skill) {
      case 'add_label': {
        const labels = Array.isArray(params.labels) ? params.labels : [];
        if (labels.length && issueNumber) {
          await github.rest.issues.addLabels({ ...context.repo, issue_number: issueNumber, labels });
          audit.push(`add_label: ${labels.join(', ')}`);
        }
        break;
      }
      case 'remove_label': {
        const labels = Array.isArray(params.labels) ? params.labels : [];
        for (const name of labels) {
          try {
            await github.rest.issues.removeLabel({ ...context.repo, issue_number: issueNumber, name });
            audit.push(`remove_label: ${name}`);
          } catch (error) {
            if (error.status !== 404) throw error;
          }
        }
        break;
      }
      case 'set_priority': {
        const priority = params.priority || String((params.labels || [])[0] || '').replace(/^priority:/, '');
        if (!['p0', 'p1', 'p2', 'p3'].includes(priority)) break;
        for (const name of ['priority:p0', 'priority:p1', 'priority:p2', 'priority:p3']) {
          try {
            await github.rest.issues.removeLabel({ ...context.repo, issue_number: issueNumber, name });
          } catch (error) {
            if (error.status !== 404) throw error;
          }
        }
        await github.rest.issues.addLabels({ ...context.repo, issue_number: issueNumber, labels: [`priority:${priority}`] });
        audit.push(`set_priority: ${priority}`);
        break;
      }
      case 'assign_issue': {
        const assignees = Array.isArray(params.assignees)
          ? params.assignees
          : params.assignee ? [params.assignee] : [];
        if (assignees.length && issueNumber) {
          await github.rest.issues.addAssignees({ ...context.repo, issue_number: issueNumber, assignees });
          audit.push(`assign_issue: ${assignees.join(', ')}`);
        }
        break;
      }
      case 'add_comment': {
        if (params.body && issueNumber) {
          await github.rest.issues.createComment({ ...context.repo, issue_number: issueNumber, body: params.body });
          audit.push('add_comment');
        }
        break;
      }
      case 'close_issue': {
        if (issueNumber) {
          await github.rest.issues.update({
            ...context.repo, issue_number: issueNumber, state: 'closed',
            state_reason: params.reason === 'not_planned' ? 'not_planned' : 'completed',
          });
          audit.push('close_issue');
        }
        break;
      }
      case 'reopen_issue': {
        if (issueNumber) {
          await github.rest.issues.update({ ...context.repo, issue_number: issueNumber, state: 'open' });
          audit.push('reopen_issue');
        }
        break;
      }
      case 'mark_duplicate': {
        const duplicateOf = params.duplicate_of || params.duplicateOf;
        if (!duplicateOf || !issueNumber) break;
        await github.rest.issues.addLabels({ ...context.repo, issue_number: issueNumber, labels: ['duplicate'] });
        await github.rest.issues.createComment({
          ...context.repo, issue_number: issueNumber,
          body: params.body || `Duplicate of #${duplicateOf}`,
        });
        audit.push(`mark_duplicate: #${duplicateOf}`);
        break;
      }
      case 'create_branch': {
        const branch = params.branch;
        if (!branch) break;
        const base = params.base || env.DEFAULT_BRANCH || 'main';
        const baseRef = await github.rest.git.getRef({ ...context.repo, ref: `heads/${base}` });
        try {
          await github.rest.git.createRef({ ...context.repo, ref: `refs/heads/${branch}`, sha: baseRef.data.object.sha });
          audit.push(`create_branch: ${branch}`);
        } catch (error) {
          if (error.status === 422) audit.push(`create_branch skipped: ${branch} exists`);
          else throw error;
        }
        break;
      }
      case 'escalate': {
        const labels = Array.isArray(params.labels) && params.labels.length ? params.labels : ['needs-human'];
        if (issueNumber) {
          await github.rest.issues.addLabels({ ...context.repo, issue_number: issueNumber, labels });
          audit.push(`escalate: ${labels.join(', ')}`);
        }
        break;
      }
      case 'link_linear': {
        const linearIssueId = params.linear_issue_id || params.issue_id || params.identifier;
        if (!linearIssueId) throw new Error('link_linear requires linear_issue_id');
        if (!env.LINEAR_TOKEN) {
          audit.push('link_linear skipped: linear-token is not configured');
          break;
        }
        const body = params.body || `GitHub issue linked: ${issueUrl}`;
        const issueData = await linearRequest(
          'query OpenCIIssue($id: String!) { issue(id: $id) { id identifier url } }',
          { id: linearIssueId },
        );
        const targetIssueId = issueData.issue?.id || linearIssueId;
        await linearRequest(
          'mutation OpenCIComment($input: CommentCreateInput!) { commentCreate(input: $input) { success comment { id url } } }',
          { input: { issueId: targetIssueId, body } },
        );
        audit.push(`link_linear: ${issueData.issue?.identifier || linearIssueId}`);
        break;
      }
      case 'dispatch_mcp_task': {
        const taskName = params.task || params.name;
        if (!taskName) throw new Error('dispatch_mcp_task requires task');
        const task = tasks.get(taskName);
        if (!task) throw new Error(`dispatch_mcp_task task is not declared: ${taskName}`);
        const eventType = params.event_type || task.event_type || 'openci-mcp-task';
        await postJson(
          `https://api.github.com/repos/${context.repo.owner}/${context.repo.repo}/dispatches`,
          env.MCP_DISPATCH_TOKEN || '',
          {
            event_type: eventType,
            client_payload: {
              source: 'openci-issue-agent',
              task: taskName,
              issue_number: issueNumber || null,
              issue_url: issueUrl,
              payload: params.payload || {},
            },
          },
        );
        audit.push(`dispatch_mcp_task: ${taskName}`);
        break;
      }
      case 'schedule_followup': {
        const dueAt = computeDueAt(params);
        const payload = {
          due_at: dueAt,
          reason: params.reason || params.body || '',
          task: params.task || 'issue-followup',
          created_by_run: context.runId,
        };
        if (issueNumber) {
          await github.rest.issues.addLabels({ ...context.repo, issue_number: issueNumber, labels: ['followup:scheduled'] });
          await github.rest.issues.createComment({
            ...context.repo,
            issue_number: issueNumber,
            body: [
              `<!-- openci-followup:${JSON.stringify(payload)} -->`,
              `OpenCI scheduled a follow-up for ${dueAt}.`,
              '',
              payload.reason || 'No follow-up reason was provided.',
            ].join('\n'),
          });
        }
        audit.push(`schedule_followup: ${dueAt}`);
        break;
      }
      case 'notify': {
        const webhook = env.NOTIFY_WEBHOOK_URL || '';
        if (!webhook) {
          audit.push('notify skipped: slack-webhook-url is not configured');
          break;
        }
        const body = params.body || params.message || `OpenCI issue agent notification for ${issueUrl}`;
        const response = await doFetch(webhook, {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ text: body, channel: params.channel, source: 'openci-issue-agent', issue_url: issueUrl }),
        });
        if (!response.ok) {
          throw new Error(`notify webhook failed: ${response.status} ${await response.text()}`);
        }
        audit.push(`notify: ${params.channel || 'webhook'}`);
        break;
      }
    }
  }

  if (issueNumber && audit.length) {
    const marker = `<!-- openci-agent-run: ${env.PLAN_HASH} -->`;
    const markerPrefix = '<!-- openci-agent-run:';
    const existing = await github.paginate(github.rest.issues.listComments, {
      ...context.repo, issue_number: issueNumber, per_page: 100,
    });
    if (!existing.some((c) => c.body && c.body.includes(markerPrefix))) {
      await github.rest.issues.createComment({
        ...context.repo,
        issue_number: issueNumber,
        body: [
          marker,
          'OpenCI issue agent executed:',
          '',
          ...audit.map((line) => `- ${line}`),
          '',
          'Reasoning:',
          env.REASONING || plan.reasoning || '',
        ].join('\n'),
      });
    }
  }

  return audit;
}

module.exports = { executeIssuePlan };
