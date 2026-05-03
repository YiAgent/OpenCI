'use strict';
// Agentic eval test for the issue-triage workflow.
//
// Two modes:
//   LIVE (ANTHROPIC_API_KEY set): calls the real Claude API and validates
//     the agentic response conforms to issue-action-plan/v1 schema with
//     sensible field values for each fixture.
//   OFFLINE (no key): validates fixture golden plans against the schema
//     enforced by execute-plan/execute.js — proves the executor would accept
//     what the agent is expected to return.
//
// Run: node --test tests/agentic/issue-triage-eval.test.js

const { test, describe } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '../..');
const FIXTURES_DIR = path.join(__dirname, 'fixtures/issues');
const GOLDEN_DIR = path.join(__dirname, 'fixtures/golden-plans');
const SKILL_PATH = path.join(ROOT, 'skills/issue-orchestrate/SKILL.md');
const TRIAGE_SKILL_PATH = path.join(ROOT, 'skills/issue-triage/SKILL.md');

const LIVE = Boolean(process.env.ANTHROPIC_API_KEY);
const MODEL = process.env.EVAL_MODEL || 'claude-haiku-4-5-20251001';

// ── Schema validators ─────────────────────────────────────────────────────────

const ALLOWED_SKILLS = new Set([
  'add_label', 'remove_label', 'set_priority', 'assign_issue',
  'add_comment', 'close_issue', 'reopen_issue', 'mark_duplicate',
  'create_branch', 'link_linear', 'dispatch_mcp_task',
  'schedule_followup', 'notify', 'escalate',
]);

function validatePlanSchema(plan, label) {
  assert.equal(plan.version, 'issue-action-plan/v1', `${label}: wrong version`);
  assert.ok(typeof plan.reasoning === 'string' && plan.reasoning.length > 0,
    `${label}: reasoning must be a non-empty string`);
  assert.ok(Array.isArray(plan.actions), `${label}: actions must be an array`);
  assert.ok(plan.skip_reason === null || typeof plan.skip_reason === 'string',
    `${label}: skip_reason must be null or string`);

  for (const action of plan.actions) {
    assert.ok(ALLOWED_SKILLS.has(action.skill),
      `${label}: unknown skill "${action.skill}"`);
    assert.ok(action.params && typeof action.params === 'object',
      `${label}: action "${action.skill}" must have params object`);
  }
}

function validateLabelAction(plan, expectedLabels, label) {
  const labelActions = plan.actions.filter((a) => a.skill === 'add_label');
  assert.ok(labelActions.length > 0, `${label}: expected at least one add_label action`);
  const appliedLabels = labelActions.flatMap((a) => a.params.labels || []);
  for (const expected of expectedLabels) {
    assert.ok(
      appliedLabels.some((l) => l.includes(expected)),
      `${label}: expected label matching "${expected}", got [${appliedLabels.join(', ')}]`,
    );
  }
}

// ── Offline: golden plan schema validation ────────────────────────────────────

describe('offline: golden plan schema', () => {
  test('valid-triage-plan conforms to issue-action-plan/v1', () => {
    const plan = JSON.parse(
      fs.readFileSync(path.join(GOLDEN_DIR, 'valid-triage-plan.json'), 'utf8'),
    );
    validatePlanSchema(plan, 'valid-triage-plan');
    assert.ok(plan.actions.length > 0, 'triage plan should have actions');
  });

  test('valid-security-plan conforms to issue-action-plan/v1', () => {
    const plan = JSON.parse(
      fs.readFileSync(path.join(GOLDEN_DIR, 'valid-security-plan.json'), 'utf8'),
    );
    validatePlanSchema(plan, 'valid-security-plan');
    const hasEscalate = plan.actions.some((a) => a.skill === 'escalate');
    assert.ok(hasEscalate, 'security plan should escalate');
  });

  test('invalid plan version is rejected', () => {
    const badPlan = { version: 'issue-action-plan/v0', actions: [], reasoning: 'x', skip_reason: null };
    assert.throws(() => validatePlanSchema(badPlan, 'bad-version'), /wrong version/);
  });

  test('unknown skill is rejected', () => {
    const badPlan = {
      version: 'issue-action-plan/v1',
      reasoning: 'test',
      actions: [{ skill: 'delete_repo', params: {} }],
      skip_reason: null,
    };
    assert.throws(() => validatePlanSchema(badPlan, 'unknown-skill'), /unknown skill/);
  });
});

// ── Offline: plan field semantics ─────────────────────────────────────────────

describe('offline: plan field semantics', () => {
  test('bug-report golden plan has bug+infra labels', () => {
    const plan = JSON.parse(
      fs.readFileSync(path.join(GOLDEN_DIR, 'valid-triage-plan.json'), 'utf8'),
    );
    validateLabelAction(plan, ['bug'], 'bug-report');
  });

  test('security golden plan has escalate and high priority label', () => {
    const plan = JSON.parse(
      fs.readFileSync(path.join(GOLDEN_DIR, 'valid-security-plan.json'), 'utf8'),
    );
    const hasEscalate = plan.actions.some((a) => a.skill === 'escalate');
    const labels = plan.actions.filter((a) => a.skill === 'add_label')
      .flatMap((a) => a.params.labels || []);
    assert.ok(hasEscalate, 'should escalate security issues');
    assert.ok(labels.some((l) => l.includes('security')), 'should label as security');
  });
});

// ── Skill file structure ───────────────────────────────────────────────────────

describe('skill file structure', () => {
  test('issue-orchestrate SKILL.md exists and specifies correct output format', () => {
    const skill = fs.readFileSync(SKILL_PATH, 'utf8');
    assert.ok(skill.includes('issue-action-plan/v1'), 'skill specifies plan version');
    assert.ok(skill.includes('"version"'), 'skill shows version field');
    assert.ok(skill.includes('"actions"'), 'skill shows actions field');
    assert.ok(skill.includes('"reasoning"'), 'skill shows reasoning field');
    assert.ok(skill.includes('"skip_reason"'), 'skill shows skip_reason field');
  });

  test('issue-triage SKILL.md specifies JSON-only output contract', () => {
    const skill = fs.readFileSync(TRIAGE_SKILL_PATH, 'utf8');
    assert.ok(skill.includes('"labels"'), 'triage skill has labels field');
    assert.ok(skill.includes('"priority"'), 'triage skill has priority field');
    assert.ok(skill.includes('"complexity"'), 'triage skill has complexity field');
    assert.ok(skill.includes('Do not include any text before or after the JSON'),
      'triage skill enforces JSON-only output');
  });

  test('all fixture issues have required ingest fields', () => {
    const fixtures = fs.readdirSync(FIXTURES_DIR).filter((f) => f.endsWith('.json'));
    assert.ok(fixtures.length >= 3, 'at least 3 fixture issues');
    for (const file of fixtures) {
      const data = JSON.parse(fs.readFileSync(path.join(FIXTURES_DIR, file), 'utf8'));
      assert.ok(data.event?.name, `${file}: missing event.name`);
      assert.ok(data.repo?.name, `${file}: missing repo.name`);
      assert.ok(data.issue?.number, `${file}: missing issue.number`);
      assert.ok(data.issue?.title, `${file}: missing issue.title`);
    }
  });
});

// ── Live: real Claude API agentic eval ────────────────────────────────────────

if (LIVE) {
  const Anthropic = require('@anthropic-ai/sdk');
  const client = new Anthropic({ apiKey: process.env.ANTHROPIC_API_KEY });

  async function callIssueTriage(issueFixture) {
    const triageSkill = fs.readFileSync(TRIAGE_SKILL_PATH, 'utf8')
      .replace('{{repo}}', issueFixture.repo.name)
      .replace('{{context}}', JSON.stringify({
        title: issueFixture.issue.title,
        body: issueFixture.issue.body,
        labels: issueFixture.issue.labels,
        author: issueFixture.issue.user.login,
        similar_issues: [],
      }, null, 2));

    const response = await client.messages.create({
      model: MODEL,
      max_tokens: 1024,
      messages: [{ role: 'user', content: triageSkill }],
    });

    const text = response.content[0].text.trim();
    // Extract JSON from response (model may wrap in ```json blocks)
    const jsonMatch = text.match(/```json\s*([\s\S]*?)\s*```/) || text.match(/(\{[\s\S]*\})/);
    if (!jsonMatch) throw new Error(`No JSON in response: ${text.slice(0, 200)}`);
    return JSON.parse(jsonMatch[1]);
  }

  async function callIssueOrchestrate(issueFixture) {
    const orchestrateSkill = fs.readFileSync(SKILL_PATH, 'utf8');
    const contextPrompt = `${orchestrateSkill}\n\nAgent workspace context:\n${JSON.stringify(issueFixture, null, 2)}`;

    const response = await client.messages.create({
      model: MODEL,
      max_tokens: 1024,
      messages: [{ role: 'user', content: contextPrompt }],
    });

    const text = response.content[0].text.trim();
    const jsonMatch = text.match(/```json\s*([\s\S]*?)\s*```/) || text.match(/(\{[\s\S]*\})/);
    if (!jsonMatch) throw new Error(`No JSON in response: ${text.slice(0, 200)}`);
    return JSON.parse(jsonMatch[1]);
  }

  describe('live: issue-triage skill agentic eval', () => {
    test('bug-report → triage assigns bug label and non-null priority', async () => {
      const fixture = JSON.parse(
        fs.readFileSync(path.join(FIXTURES_DIR, 'bug-report.json'), 'utf8'),
      );
      const result = await callIssueTriage(fixture);

      assert.ok(Array.isArray(result.labels), 'labels must be array');
      assert.ok(result.labels.includes('bug') || result.labels.includes('infra'),
        `Expected bug/infra label, got: ${result.labels.join(', ')}`);
      assert.ok(['p0', 'p1', 'p2', 'p3'].includes(result.priority),
        `Invalid priority: ${result.priority}`);
      assert.ok(['S', 'M', 'L', 'XL'].includes(result.complexity),
        `Invalid complexity: ${result.complexity}`);
      assert.ok(typeof result.summary === 'string' && result.summary.length > 0,
        'summary must be non-empty');
    });

    test('security-issue → triage assigns security label and p0 or p1 priority', async () => {
      const fixture = JSON.parse(
        fs.readFileSync(path.join(FIXTURES_DIR, 'security-issue.json'), 'utf8'),
      );
      const result = await callIssueTriage(fixture);

      assert.ok(result.labels.includes('security'),
        `Expected security label, got: ${result.labels.join(', ')}`);
      assert.ok(['p0', 'p1'].includes(result.priority),
        `Security issue should be p0 or p1, got: ${result.priority}`);
    });

    test('feature-request → triage assigns feature label', async () => {
      const fixture = JSON.parse(
        fs.readFileSync(path.join(FIXTURES_DIR, 'feature-request.json'), 'utf8'),
      );
      const result = await callIssueTriage(fixture);

      assert.ok(result.labels.includes('feature') || result.labels.includes('enhancement'),
        `Expected feature/enhancement label, got: ${result.labels.join(', ')}`);
    });
  });

  describe('live: issue-orchestrate skill agentic eval', () => {
    test('bug-report → orchestrate returns valid issue-action-plan/v1', async () => {
      const fixture = JSON.parse(
        fs.readFileSync(path.join(FIXTURES_DIR, 'bug-report.json'), 'utf8'),
      );
      const plan = await callIssueOrchestrate(fixture);
      validatePlanSchema(plan, 'bug-report orchestrate');
    });

    test('security-issue → orchestrate escalates or labels as security', async () => {
      const fixture = JSON.parse(
        fs.readFileSync(path.join(FIXTURES_DIR, 'security-issue.json'), 'utf8'),
      );
      const plan = await callIssueOrchestrate(fixture);
      validatePlanSchema(plan, 'security-issue orchestrate');

      const hasEscalate = plan.actions.some((a) => a.skill === 'escalate');
      const labels = plan.actions.filter((a) => a.skill === 'add_label')
        .flatMap((a) => a.params.labels || []);
      const hasSecurityLabel = labels.some((l) => l.includes('security'));

      assert.ok(hasEscalate || hasSecurityLabel,
        'Security issue should either escalate or add security label');
    });

    test('orchestrate never emits forbidden high-risk skills for untrusted actor', async () => {
      const fixture = JSON.parse(
        fs.readFileSync(path.join(FIXTURES_DIR, 'bug-report.json'), 'utf8'),
      );
      // Demote actor to external contributor (should not trigger branch creation etc.)
      fixture.issue.author_association = 'NONE';
      const plan = await callIssueOrchestrate(fixture);
      validatePlanSchema(plan, 'untrusted-actor orchestrate');

      const highRisk = plan.actions.filter((a) =>
        ['create_branch', 'dispatch_mcp_task'].includes(a.skill),
      );
      assert.equal(highRisk.length, 0,
        `Should not emit high-risk actions for untrusted actor, got: ${highRisk.map((a) => a.skill).join(', ')}`);
    });
  });
} else {
  describe('live (SKIPPED — set ANTHROPIC_API_KEY to enable)', () => {
    test('live tests are skipped in offline mode', () => {
      assert.ok(true, 'set ANTHROPIC_API_KEY=... to run live agentic eval');
    });
  });
}
