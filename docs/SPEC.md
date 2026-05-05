# OpenCI 共享工作流库 — 设计规格文档

**版本**：v2.0
**用途**：可直接交给 Claude Code 实施的完整设计规格
**仓库定位**：公开 GitHub 仓库，供自己多个项目及外部项目通过 `uses:` 引用

---

## 变更日志

### v2.0(本版) — Agentic 架构重构

**全面转向 agentic 4-stage 流水线架构。所有核心工作流现在遵循
Ingest → Enrich → Agent → Execute 模式，Claude 作为结构化决策引擎嵌入每个阶段。**

主要变更:
- 12 个 `reusable-*.yml` 工作流 + 12 个 event entry 文件
- 15 个内置 AI skill (`skills/` 目录)
- Agent context 系统 (`.github/agent/` 目录: shared / pr / issue / docs / observe)
- 多 provider 可观测性 (Sentry / PostHog / Axiom / Datadog / LangSmith → Claude incident analyst)
- 自主 staging 测试 (L1–L4 Playwright browser automation)
- Docs sync agent (drift detection → Claude action plan → auto-PR)
- Maintenance analyst (CVE correlation → dependency intelligence → auto-issue)
- 旧的单文件工作流模式已移除，所有 workflow 使用 `reusable-*.yml` 命名规范

**历史版本**(v1.0–v1.7)归档至 `docs/CHANGELOG-history.md`。

---

## 一、项目概述与设计原则

### 1.1 项目定位

本仓库是一个 GitHub Actions 共享库，提供三层可复用单元 + AI agent 能力:

- **Reusable Workflow** (`reusable-*.yml`)：完整的阶段流水线，调用方一行引入
  `uses: YiAgent/OpenCI/.github/workflows/reusable-pr.yml@v3`
- **Composite Action**：阶段内的组合逻辑，封装多个原子
  `uses: YiAgent/OpenCI/actions/pr/lint-code@v3`
- **原子 Action**：最小职责单元，单一功能，明确输入输出
  `uses: YiAgent/OpenCI/actions/pr/lint-node@v3`
- **AI Skill** (`skills/`)：Claude 任务提示词，通过 claude-harness 执行

所有涉及 AI 的步骤统一通过 `claude-harness` 执行，不直接在各 action 中调用 Claude API。

### 1.2 双重身份架构

OpenCI 有两个明确身份:

1. **普通项目**：通过 12 个 event entry 文件 dogfood 自己的工作流
2. **工具库**：暴露 12 个 `reusable-*.yml` 供外部消费

Event entry 文件是 OpenCI 自己的薄包装器，外部消费者应编写自己的 event entry。

### 1.3 4-Stage Agentic Pipeline

核心工作流遵循统一的 4 阶段模式:

| Stage | 目的 | 示例 |
| --- | --- | --- |
| **1. Ingest / Detect** | 确定性数据收集 | 解析 issue form、检测语言、构建 Docker、运行 lint |
| **2. Enrich** | 从 stage 1 结果构建 agent workspace | 合并 gate 结果 + 实时 PR/issue 数据到 context JSON |
| **3. Agent** | Claude 产生结构化 action plan | `pr-action-plan/v1`、`issue-action-plan/v1`、`docs-action-plan/v1`、`observe-action-plan/v1` |
| **4. Execute** | 受保护的 allowlisted 执行 | 发评论、创建 issue、触发部署、执行回滚 |

此模式出现在: `reusable-pr`、`reusable-issue`、`reusable-docs`、`reusable-observability`、`reusable-ci`(仅失败时 agent)、`reusable-maintenance`。

### 1.4 五条设计原则

#### 原则一：变化频率决定位置

Prompt 独立于 Action 存放，因为两者变化频率不同。Action 结构数月不变，Prompt 每周调优。Scripts 跟随调用它的 Action，不集中存放，除非被两个以上 Action 共用才提到 `lib/`。第三方依赖的 SHA 集中维护在 `manifest.yml`，因为它需要全仓库统一更新。

具体落点:

- Prompt → `skills/{task}/SKILL.md`
- Agent context → `.github/agent/{domain}/context/AGENTS.md`
- Action 实现 → `actions/{stage}/{name}/`
- 工作流主干 → `.github/workflows/reusable-*.yml`
- 复用脚本 → 跟随 action，2+ 共用才提到 `lib/`
- 第三方 SHA → `manifest.yml` 的 `deps` 节点（**唯一来源**）

#### 原则二：命名即语义

Action 命名格式:`动词-名词`（`lint-node`、`scan-deps`、`tag-release`）。目录命名格式:名词（`issue`、`pr`、`stg`、`prd`）。Composite 与原子同在阶段目录下，通过名称复杂度区分粒度，不单独建 `composites/` 目录。

固定动词词汇表:

| 动词 | 语义 | 例 |
| --- | --- | --- |
| `detect-` | 探测识别 | `detect-language` |
| `lint-` | 静态检查 | `lint-code` |
| `scan-` | 安全扫描 | `scan-deps`, `scan-secrets`, `scan-image` |
| `test-` | 测试执行 | `test-unit` |
| `build-` | 构建产物 | `build-docker` |
| `check-` | 条件验证（pass/fail） | `check-coverage`, `check-migration` |
| `verify-` | 交叉对比 | `verify-version-align` |
| `observe-` | 监控等待 | `observe-window` |
| `deploy-` | 部署到环境 | `deploy-k8s` |
| `sign-` | 签名加密 | `sign-image` |
| `notify-` | 发送通知 | `notify-deployed` |
| `create-` | 创建资源 | `create-release` |
| `review-` | 审查 | `review-ai` |
| `enrich-` | 构建 agent workspace | `enrich` |
| `extract-` | 提取结构化数据 | `extract-plan` |
| `execute-` | 执行 agent plan | `execute-plan` |

#### 原则三：调用层级单向

主工作流调用 Composite，Composite 调用原子，原子不互相调用。AI 调用统一通过 claude-harness 入口，不直接调用 Claude API。

```
Reusable Workflow (reusable-*.yml)
  └── Composite Action（阶段级，job ≙ composite，一对一映射）
        └── 原子 Action（单一功能）
              └── （AI 原子专属）→ _common/claude-harness（composite，内联调用）

独立 AI Job 调用链:
  Reusable Workflow job → reusable-agent.yml（reusable workflow，uses 引入）
                 └── 内部调用 _common/claude-harness composite
```

**Job ≙ Composite 一对一映射规则**:

主工作流的每个 job 名称应与其调用的 composite 名称一致。一个 job 只调一个 composite，不在 job 内串多个 composite。

**claude-harness 双层调用判定规则**:

| 场景 | 用 composite | 用 reusable workflow |
| --- | --- | --- |
| 在原子 action 内部嵌入一次 AI 调用 | ✓ | — |
| 主工作流的某个 job 完整就是一次 AI 任务 | — | ✓ |
| AI 调用需要独立 job 级别的 timeout / permissions / secrets | — | ✓ |
| AI 调用嵌在某个原子的 step 序列中 | ✓ | — |

判定原则:**AI 调用是 job 中的一个 step → composite;AI 调用是整个 job → reusable workflow**。

#### 原则四：外部优于自实现

有成熟的 Verified Creator action 时，优先封装使用，不重复造轮子。自实现仅用于:无现成方案、命令因项目而异、业务规则特定。

反模式:不得自实现 Docker 构建、secret 扫描、覆盖率上报等已有成熟方案的功能。

#### 原则五：安全默认

供应链攻击是 GitHub Actions 生态的实质性威胁。设计上必须假定每个第三方 action 都可能被劫持。因此:

- **SHA 固定**:所有第三方 action 必须使用 commit SHA，不接受版本 tag
- **SHA 集中**:所有 SHA 维护在 `manifest.yml`，不在 action 内硬编码
- **权限最小化**:每个 job 显式声明 `permissions`，仅开放必要权限
- **harden-runner 必装**:每个工作流每个 job 第一步统一加载，审计出站连接
- **OIDC 优先**:认证使用 OIDC（id-token），避免长期凭证

---

## 二、目录结构

仓库分四个顶层区域，按"变化频率"原则分离:

```
openCI/
├── .github/                              # 工作流 + GitHub 原生模板
│   ├── workflows/                        # 12 event entries + 12 reusable workflows
│   ├── ISSUE_TEMPLATE/                   # YAML form 模板
│   ├── PULL_REQUEST_TEMPLATE.md
│   ├── CODEOWNERS / labeler.yml / auto-assign.yml
│   ├── renovate.json
│   ├── scripts/                          # cross-workflow shell helpers
│   └── agent/                            # Agent context 系统
│       ├── shared/                       #   共享 context + skills (add-comment, escalate, notify)
│       ├── pr/                           #   PR agent context + 8 skills
│       ├── issue/                        #   Issue agent context + 8 skills
│       ├── docs/                         #   Docs agent context + rules
│       └── observe/                      #   Observability agent context + provider guides
│
├── actions/                              # action 实现，按阶段分目录
│   ├── _common/                          #   claude-harness / detect-language / notify-deployed
│   │                                     #   / run-migration / check-trust / api-key-gate
│   │                                     #   / resolve-openci / flag-audit / gitleaks-artifact
│   │                                     #   / schedule-prd-dispatch / poll-prd-dispatch / scan-zizmor
│   ├── pr/                               #   18 PR quality gate atoms
│   ├── ci/                               #   5 CI atoms (scan-image, sign-image, build-docker, eval-smoke, check-migration)
│   ├── stg/                              #   4 staging atoms (deploy-k8s, perf-baseline, agent-test, smoke-test)
│   ├── prd/                              #   10 production atoms
│   ├── deploy/                           #   3 deploy atoms (docker, auto-rollback-docker, preflight)
│   ├── issue/                            #   5 issue lifecycle atoms
│   ├── integrations/                     #   7 SaaS integration atoms
│   ├── security/                         #   5 security scan atoms
│   ├── maintenance/                      #   3 maintenance atoms
│   └── docs/                             #   3 docs atoms (detect, extract-plan, execute-plan)
│
├── skills/                               # 15 built-in Claude task prompts
│   └── {skill-name}/SKILL.md             # pr-review-agent, issue-orchestrate, ci-failure-analyst, etc.
│
├── tests/                                # bats suites + fixtures + workflow reports
│
├── docs/                                 # SPEC.md + setup guides + design plans
│
├── manifest.yml                          # 第三方 SHA 注册表(已验证，191 references)
└── README / LICENSE(MIT) / CHANGELOG / CONTRIBUTING /
    CODE_OF_CONDUCT / SECURITY
```

**工作流清单**:

| 类别 | 文件 | 数量 |
| --- | --- | --- |
| Reusable workflows | `reusable-agent.yml`, `reusable-ci.yml`, `reusable-pr.yml`, `reusable-issue.yml`, `reusable-stg.yml`, `reusable-prd.yml`, `reusable-observability.yml`, `reusable-release.yml`, `reusable-docs.yml`, `reusable-maintenance.yml`, `reusable-deps.yml`, `reusable-self-test.yml` | 12 |
| Event entries | `agent.yml`, `ci.yml`, `pull-request.yml`, `issue-ops.yml`, `release.yml`, `docs.yml`, `on-maintenance.yml`, `auto-release.yml`, `on-main-bump-sha.yml`, `dependencies.yml`, `ci-self-test.yml`, `test.yml` | 12 |

---

## 三、Action Manifest 注册表

`manifest.yml` 是全仓库的单一来源索引。所有 workflow / action 文件直接写 SHA，`manifest.yml` 作为**校验源**:CI 在 PR 上跑一致性检查，确保仓库里所有 SHA 与 manifest 完全一致。

**关键约定**:

1. `deps:` 段只放**已验证 SHA**。占位条目必须放 `manifest-pending.yml`，不进主 manifest。
2. CI 检查 job(`verify-sha-consistency`)读 `manifest.yml` 与所有 workflow / action 文件，任何不一致 → check 失败。
3. 新增第三方 action → 先填 `manifest-pending.yml`，验证通过后人工迁移到 `manifest.yml`，同步替换文件中的 SHA。

### 3.1 SHA 验证流程

**SHA 验证 checklist**(完成全部才能迁移到主 manifest):

1. 在 GitHub 上访问 action 仓库的 `commits/<tag>` 页面，确认 SHA 与 tag 关联无误
2. 用 `npx pin-github-action` 在测试 workflow 上 pin 一次，对照输出 SHA
3. 高敏感 action(harden-runner / cosign / trivy)额外 `cosign verify-blob` 校验 release artifact 签名
4. 验证通过 → PR 把条目从 `manifest-pending.yml` 剪切到 `manifest.yml`，同步替换 workflow / action 文件中的占位符

---

## 四、语言检测单一来源

**文件**:`actions/_common/detect-language/action.yml`

**职责**:根据仓库根目录文件探测语言栈，输出标准化语言标识符。所有需要语言信息的工作流均通过此 action 获取，不允许各工作流自行实现检测逻辑。

**输出**:

```yaml
outputs:
  language:           # node | python | go | java | kotlin | unknown
  package-manager:    # npm | pnpm | yarn | uv | pip | go-mod | maven | gradle | gradle-kts | unknown
  version-file:       # .nvmrc | .python-version | go.mod | pom.xml | build.gradle | ""
  runtime-version:    # 从 version-file 读取的版本号
```

**检测规则**（优先级从高到低，找到即停）:

```
1. package.json 存在 → language=node
   ├── pnpm-lock.yaml    → package-manager=pnpm
   ├── yarn.lock         → package-manager=yarn
   └── package-lock.json → package-manager=npm（默认）

2. pyproject.toml 或 requirements.txt 存在 → language=python
   ├── uv.lock → package-manager=uv
   └── 否则   → package-manager=pip

3. go.mod 存在 → language=go, package-manager=go-mod

4. JVM 项目检测:
   ├── pom.xml 存在                 → language=java,   package-manager=maven
   ├── build.gradle.kts 存在        → language=kotlin, package-manager=gradle-kts
   ├── build.gradle 存在            → language=java,   package-manager=gradle
   version-file: pom.xml | build.gradle | build.gradle.kts

5. 全部未匹配 → language=unknown
```

**实现**:纯 shell composite action，不引用任何外部 action，保证零依赖。

---

## 五、Reusable Workflow 规格

### 5.1 reusable-agent.yml — Claude Harness

所有 AI 调用的单一入口。包装 `anthropics/claude-code-action`，统一管理模型参数、prompt 解析、工具白名单、MCP 配置、sticky comment。

**关键特性**:

- **Prompt 解析链**: direct text → slash-command (`.claude/commands/<cmd>.md`) → caller-provided file → built-in `skills/<task>/SKILL.md`
- **Mustache 模板**: `{{repo}}`, `{{run_id}}`, `{{event_name}}`, `{{ref}}`, `{{sha}}`, `{{actor}}` + 任意 `context` JSON keys
- **工具白名单**: 基线工具 (file ops, git, jq, gh, curl, sha256sum) + 调用方可扩展 `extra-allowed-tools`
- **多 provider**: Anthropic, AWS Bedrock, Google Vertex AI, Microsoft Foundry
- **MCP 集成**: 通过 `mcp-config` input 配置

**Inputs**:

| Input | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `task` | string | 必填 | 任务标识，用于解析 `skills/<task>/SKILL.md` |
| `prompt` | string | "" | 直接 prompt 文本或 slash command |
| `prompt-path` | string | "" | prompt 文件路径（相对调用方仓库） |
| `context` | string | "{}" | JSON 对象，keys 成为 `{{name}}` 模板变量 |
| `model` | string | claude-sonnet-4-5-20250929 | AI 模型名 |
| `max-turns` | number | 10 | 最大交互轮数 |
| `api-provider` | string | anthropic | anthropic / bedrock / vertex / foundry |
| `timeout-minutes` | number | 30 | 超时分钟数 |
| `extra-allowed-tools` | string | "" | 额外允许的工具列表 |
| `extra-disallowed-tools` | string | "" | 额外禁止的工具列表 |
| `mcp-config` | string | "" | MCP server 配置 JSON |
| `use-sticky-comment` | boolean | true | 使用 sticky comment 模式 |

**Secrets**: `api-key`(可选), `oauth-token`(可选), `api-base-url`(可选), `github-token`(可选), `slack-webhook`(可选)

**Outputs**: `execution-file`, `session-id`, `structured-output`, `prompt-source`

**Jobs**: `preflight`(credential check) → `ai-task`(runs claude-harness)

### 5.2 reusable-pr.yml — PR Quality Gate (4-stage)

**Stage 1 — Gate** (确定性，全部并行):
`preflight` → `detect-language` → 并行: `auto-label` / `auto-assign` / `validate-pr-title` / `validate-pr-desc` / `scan-deps` / `scan-secrets` / `scan-sonarcloud` / `verify-sha` / `lint` / `test` / `coverage` / `build-check` / `ai-review` / `eval-prompt` / `copilot-review`

**Stage 2 — Enrich**: 构建 agent workspace，合并所有 gate 结果到 context JSON

**Stage 3 — Agent**: Claude 产生 `pr-action-plan/v1` JSON (结构化 review 评论)

**Stage 4 — Execute**: 发布 sticky summary comment，执行 allowlisted actions

**Inputs**:

| Input | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `language` | string | "" | 覆盖语言检测 |
| `enable-ai-review` | boolean | true | 启用 AI review |
| `enable-eval` | boolean | false | 启用 prompt eval |
| `coverage-threshold` | number | 80 | 覆盖率阈值 |
| `pr-review-prompt-path` | string | "" | 自定义 review prompt |
| `enable-copilot-review` | boolean | false | 启用 Copilot review |

### 5.3 reusable-ci.yml — Merge-to-Main Build (4-stage)

**Stage 1 — Build**: `preflight` → `detect-language` → `build-docker`

**Stage 2 — Verify** (并行): `scan-image` / `sign-image` / `verify-sha` / `generate-sbom` / `check-migration` / `eval-smoke`

**Stage 3 — Agent** (仅失败时): `enrich` → CI failure analyst skill

**Stage 4 — Dispatch**: deploy gate → trigger deploy workflow

**Outputs**: `image-digest`, `deploy-time`, `deploy-ready`

### 5.4 reusable-issue.yml — Issue Orchestrator (4-stage)

**Mode**: `lifecycle` / `maintenance` / `ingest`

**Stage 1 — Ingest**: 确定性 issue 管理 (解析 form、打 label、收集 duplicates、打包 payload)

**Stage 2 — Enrich**: 合并 `.github/agent/shared` + `.github/agent/issue` context/skills + Sentry + Linear 数据

**Stage 3 — Agent**: Claude 返回 `issue-action-plan/v1` JSON

**Stage 4 — Execute**: 校验 schema + skill allowlist + 权限后执行 GitHub mutation + 审计评论

**允许的 skill**: `add_label`, `remove_label`, `set_priority`, `assign_issue`, `add_comment`, `close_issue`, `reopen_issue`, `mark_duplicate`, `create_branch`, `link_linear`, `dispatch_mcp_task`, `schedule_followup`, `notify`, `escalate`

**安全边界**: Agent 只规划，Executor 执行。外部 contributor 评论不能触发高风险动作。

### 5.5 reusable-stg.yml — Staging Deploy

**链路**: `preflight` → `coverage-gate` → `perf-baseline` → `deploy` → `run-migration` → `smoke-test` → `auto-rollback`(失败时) → `notify-observability` → `schedule-prd-dispatch` → `notify-deployed`

**Deploy 路径**: docker / k8s 两种模式

### 5.6 reusable-prd.yml — Production Deploy

**链路**: `preflight` → `pre-check`(verify-version-align + observe-window + Sentry error-rate gate) → `deploy` → `run-migration` → `smoke-test` → `auto-rollback`(失败时) → `create-release` + `notify-deployed`

**Environment 审批**: deploy-k8s 与 run-migration job 显式声明 `environment: production`

**回滚策略**: smoke-test 失败时 `kubectl rollout undo` + 自动创建 P1 incident issue

### 5.7 reusable-observability.yml — Multi-Provider Observability (4-stage)

**Mode**: `canary-watch` / `terraform-drift` / `verify-fix` / `multi-observe`

**multi-observe 4-stage pipeline**:

1. **Collect**: Adapters 从各 provider 拉取 metrics (Sentry / PostHog / Axiom / Datadog / LangSmith)
2. **Normalize**: 合并 metrics，评估阈值
3. **Agent**: Claude 作为 incident-analyst 评估状态 (healthy / degraded / critical)
4. **Execute**: `trigger_rollback` / `create_incident` / `notify` / `extend_observe` / `promote_canary` / `escalate`

### 5.8 reusable-docs.yml — Docs Quality + Sync Agent (4-stage)

**Stage 1 — Lint**: markdownlint, link check, spell check

**Stage 2 — Detect**: git-history drift, API staleness, CHANGELOG staleness

**Stage 3 — Agent**: Claude 产生 `docs-action-plan/v1`

**Stage 4 — Execute**: 应用更新，构建/deploy Pages，发评论

### 5.9 reusable-maintenance.yml — Security + Dependency Intelligence (4-stage)

**Stage 1 — Scan** (并行): Trivy CVE, gitleaks secrets, CodeQL SAST

**Stage 2 — Update**: 查询 pending Renovate/Dependabot PRs

**Stage 3 — Enrich**: 聚合信号到 context.json

**Stage 4 — Agent**: Claude 关联 CVE 与依赖，创建 actionable issues

### 5.10 reusable-release.yml — Marketplace + Docker Release

**Mode**: `marketplace` / `docker` / `both`

- **Marketplace**: GitHub Release + floating major/minor tags
- **Docker**: build-push + cosign keyless signing

### 5.11 reusable-deps.yml — Renovate Auto-Merge

单 job: 为 `renovate[bot]` 的 `patch` label PR 启用 GitHub native auto-merge。

### 5.12 reusable-self-test.yml — Workflow/Action Validation

**Stage 1 — Lint**: actionlint, yamllint, shellcheck, pyflakes

**Stage 2 — Security**: zizmor, verify-sha, workflow-audit, bats-tests

**Stage 3 — Summary**

---

## 六、Agent Context 系统

### 6.1 目录结构

```
.github/agent/
  shared/                    # 所有 domain agent 共享
    context/AGENTS.md        # 共享规则 (escalate, secrets, concise comments)
    skills/
      add-comment.md         # 发评论
      escalate.md            # 升级到人工
      notify.md              # webhook 通知
  pr/                        # PR domain
    context/AGENTS.md        # PR 专属规则 + 8 个 allowed skills
    skills/
      add-label.md, add-reviewer.md, assign-issue.md,
      block-merge.md, escalate.md, remove-label.md,
      request-changes.md
  issue/                     # Issue domain
    context/AGENTS.md        # Issue 专属规则 + 14 个 allowed skills
    skills/
      add-label.md, assign-issue.md, branch-create.md,
      duplicate.md, linear-sync.md, mcp-task.md,
      schedule-followup.md
  docs/                      # Docs domain
    context/
      changelog-format.md    # CHANGELOG 格式规则
      rules.md               # Docs agent 规则
      structure.md           # 文档结构规范
  observe/                   # Observability domain
    context/
      providers.md           # 5 provider signal 解读指南
      rules.md               # Observability agent 规则
```

### 6.2 Agent Workspace 构建

每个 agent 使用 shared + domain 两层 workspace:

```
Enrich 阶段:
  1. 加载 .github/agent/shared/context/AGENTS.md
  2. 加载 .github/agent/{domain}/context/AGENTS.md
  3. 加载 .github/agent/{domain}/skills/*.md
  4. 合并 stage 1 数据 (gate results, issue data, metrics)
  5. 输出 agent-workspace/ → 传给 claude-harness
```

### 6.3 Action Plan Schema

Agent 输出严格 JSON:

```json
{
  "version": "<domain>-action-plan/v1",
  "reasoning": "short audit explanation",
  "actions": [],
  "skip_reason": null
}
```

各 domain 的 action plan:
- `pr-action-plan/v1`: PR review 结构化评论
- `issue-action-plan/v1`: Issue lifecycle 动作
- `docs-action-plan/v1`: 文档更新计划
- `observe-action-plan/v1`: 可观测性事件响应

---

## 七、内置 AI Skills (15)

| Skill | Domain | 说明 |
| --- | --- | --- |
| `pr-review-agent` | PR | 结构化 PR review action planning |
| `pr-review` | PR | PR code review |
| `pr-test-gen` | PR | 测试脚手架生成 |
| `issue-orchestrate` | Issue | Issue lifecycle action planning |
| `issue-triage` | Issue | Issue 分类和优先级 |
| `ci-failure-analyst` | CI | CI 失败分析和修复建议 |
| `ci-smoke-eval` | CI | Docker 镜像冒烟评估 |
| `stg-agent-test` | Deploy | 自主 staging 测试 (L1–L4) |
| `docs-sync-agent` | Docs | 文档同步 |
| `maintenance-analyst` | Maintenance | CVE/依赖关联分析 |
| `agents-ai-changelog` | Release | Keep-a-Changelog 风格 release notes |
| `agents-docubot` | Docs | 仓库文档 Q&A |
| `ops-error-triage` | Observability | Sentry 错误去重 |
| `ops-flag-audit` | Maintenance | Feature flag 卫生检查 |
| `ops-summarize-failure` | CI | CI 失败摘要 |

每个 skill 的 `SKILL.md` 包含完整的 prompt 模板，支持 Mustache 变量替换。

---

## 八、外部服务集成

### 8.1 集成总览

| 服务 | 角色 | 集成点 | 必要性 |
| --- | --- | --- | --- |
| Sentry | 错误追踪 + 发布通知 | reusable-prd.yml, reusable-observability.yml | 强烈推荐 |
| SonarCloud | 代码质量门 | reusable-pr.yml | 推荐 |
| PostHog | 产品分析 + LLM 可观测 | reusable-observability.yml | AI 项目推荐 |
| Datadog | 基础设施监控 | reusable-observability.yml | 可选 |
| LangSmith | LLM 可观测 | reusable-observability.yml | AI 项目推荐 |
| Axiom | 结构化日志 | reusable-observability.yml | 可选 |
| Slack | 通知 | 所有 deploy/CI workflow | 强烈推荐 |
| Linear | Issue tracker 同步 | reusable-issue.yml (link_linear skill) | 用 Linear 时启用 |
| Snyk | 漏洞扫描 | reusable-pr.yml | 商业项目可选 |

### 8.2 可观测性 Push 模式

`actions/integrations/notify-deploy/action.yml` — Composite，扇出到 5 个原子:

| 服务 | 推送方式 | Action |
| --- | --- | --- |
| Sentry | 创建 release | `sentry-release` |
| Datadog | submit deployment event | `datadog-event` |
| PostHog | capture 自定义事件 | `posthog-event` |
| LangSmith | 给 traces 打 deployment 标签 | `langsmith-tag` |
| Axiom | 写一条 deployment log | `axiom-event` |

**关键设计点**:
- `continue-on-error: true`: 推送失败绝不阻断部署
- 每个原子内部 `timeout 30s` + 失败静默
- fan-out 在 composite 而非 workflow

### 8.3 可观测性 Pull 模式 (multi-observe)

`reusable-observability.yml` 的 `multi-observe` 模式:

1. **Collect**: 5 个 provider adapters 拉取 metrics
2. **Normalize**: 合并 + 阈值评估
3. **Agent**: Claude 作为 incident-analyst
4. **Execute**: rollback / incident / notify / extend / promote / escalate

---

## 九、安全规范

### 9.1 SHA 固定操作

所有 action 文件中的第三方 `uses:` 必须使用完整 40 位 commit SHA。`manifest.yml` 作为验证源。CI 检查 job 确保一致。

### 9.2 权限最小化矩阵

| 工作流 | contents | pull-requests | security-events | id-token | packages | issues |
|--------|----------|---------------|-----------------|----------|----------|--------|
| reusable-agent | read | write | - | write | - | write |
| reusable-pr | read | write | write | write | - | - |
| reusable-ci | read | - | write | write | write | - |
| reusable-stg | read | - | - | write | read | - |
| reusable-prd | read | write | - | write | read | - |
| reusable-maintenance | read | - | write | - | - | - |
| reusable-issue | read | write | - | - | - | write |

**全局默认**:工作流顶层 `permissions: {}` 拒绝所有，job 级别精确授权。

### 9.3 harden-runner 统一配置

每个工作流的每个 job 第一步:

```yaml
steps:
  - name: Harden runner
    uses: step-security/harden-runner@{SHA}
    with:
      egress-policy: audit
```

### 9.4 禁止事项

1. 任何 action 直接调用 Claude API（必须经由 claude-harness）
2. 第三方 action 使用版本 tag（必须用 40 位 commit SHA）
3. SHA 在 manifest.yml 与 workflow / action 文件之间不一致
4. Composite Action 调用另一个 Composite Action
5. 工作流直接调用原子 Action（必须经由 Composite）
6. 原子 Action 之间互相调用
7. 一个 job 串多个 composite
8. `pull_request_target` 触发器 checkout PR head 代码后执行
9. 自实现 Docker 构建、secret 扫描、覆盖率上报等有成熟方案的功能
10. 省略 `harden-runner` 步骤
11. `reusable-prd.yml` 的 deploy-k8s job 缺 `environment: production`

---

## 十、Concurrency 在 Reusable Workflow 中的语义

所有主工作流都是 reusable workflow(`on: workflow_call`)，内部使用的 `${{ github.* }}` 表达式遵循"调用方上下文"规则。

**关键事实**:

| 表达式 | 在 reusable workflow 内部的值 |
| --- | --- |
| `github.ref` | **调用方**的 ref |
| `github.sha` | **调用方**的 sha |
| `github.event_name` | **调用方**的事件类型 |
| `github.repository` | **调用方**的仓库 |
| `github.run_id` | 当前(被调用)workflow 的 run id |
| `inputs.<x>` | `with:` 传入的值 |

**Concurrency 设计模式**:

```yaml
# reusable-pr.yml — 同一 PR 多次 push，取消旧 run
concurrency:
  group: pr-${{ github.event.pull_request.number }}
  cancel-in-progress: true

# reusable-ci.yml — 同 ref 串行，不取消
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: false

# reusable-agent.yml — 每次调用独立
concurrency:
  group: agent-${{ github.run_id }}
  cancel-in-progress: false
```

---

## 十一、版本管理与发布

### 11.1 语义化版本

```
v{MAJOR}.{MINOR}.{PATCH}

MAJOR:破坏性变更（输入/输出接口变更，消费方需修改引用）
MINOR:新增功能（向后兼容）
PATCH:Bug 修复（行为不变）
```

**主版本 tag 浮动**:`v3` 始终指向 `v3.x.x` 最新版。

### 11.2 Auto-Release

`auto-release.yml` 在每次 push to main 时自动分析 conventional commits，确定 bump type (major/minor/patch)，创建并推送新 tag。

### 11.3 release-drafter

`release-drafter` 基于 PR 生成 CHANGELOG draft。

---

## 十二、消费方集成示例

### 12.1 最简集成 (Node.js PR)

```yaml
# .github/workflows/on-pr.yml
name: on-pr
on: { pull_request: }
jobs:
  quality:
    uses: YiAgent/OpenCI/.github/workflows/reusable-pr.yml@v3
    with:
      enable-ai-review: true
    secrets:
      anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
```

### 12.2 完整 CI/CD 链路

```yaml
# .github/workflows/on-ci.yml
name: CI & Deploy
on: { push: { branches: [main] } }
jobs:
  build:
    uses: YiAgent/OpenCI/.github/workflows/reusable-ci.yml@v3
    with:
      image-name: my-app
    secrets:
      registry-token: ${{ secrets.GITHUB_TOKEN }}

  deploy-stg:
    needs: build
    uses: YiAgent/OpenCI/.github/workflows/reusable-stg.yml@v3
    with:
      image-digest: ${{ needs.build.outputs.image-digest }}
      image-name: my-app
      app-name: my-app
      health-url: https://stg.example.com/health
    secrets:
      kubeconfig-stg: ${{ secrets.KUBECONFIG_STG }}
```

### 12.3 Issue Agent Orchestration

```yaml
# .github/workflows/on-issue.yml
name: on-issue
on:
  issues: { types: [opened, reopened, edited, closed] }
  issue_comment: { types: [created] }
  schedule:
    - cron: '0 2 * * *'
jobs:
  orchestrate:
    uses: YiAgent/OpenCI/.github/workflows/reusable-issue.yml@v3
    with:
      mode: lifecycle
    secrets:
      anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
```

### 12.4 Ad-hoc AI Tasks

```yaml
# .github/workflows/on-agent.yml
name: on-agent
on: { workflow_dispatch: }
jobs:
  task:
    uses: YiAgent/OpenCI/.github/workflows/reusable-agent.yml@v3
    with:
      task: pr/review
      prompt: "Review the latest changes and summarize risks"
    secrets:
      api-key: ${{ secrets.ANTHROPIC_API_KEY }}
```

### 12.5 Multi-Provider Observability

```yaml
# .github/workflows/on-observe.yml
name: on-observe
on:
  workflow_run:
    workflows: [deploy-prd]
    types: [completed]
jobs:
  observe:
    uses: YiAgent/OpenCI/.github/workflows/reusable-observability.yml@v3
    with:
      environment: production
      mode: multi-observe
      providers: sentry,posthog,langsmith
      thresholds-file: .github/observe-thresholds.yml
    secrets:
      SENTRY_TOKEN: ${{ secrets.SENTRY_TOKEN }}
      POSTHOG_API_KEY: ${{ secrets.POSTHOG_API_KEY }}
      LANGSMITH_API_KEY: ${{ secrets.LANGSMITH_API_KEY }}
      anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
```

---

## 十三、GitHub 原生模板与仓库约定

### 13.1 Issue Templates (YAML Form)

`.github/ISSUE_TEMPLATE/` 提供结构化模板: `bug-report.yml`, `feature-request.yml`, `question.yml`, `security-report.yml`。

### 13.2 PR Template

`.github/PULL_REQUEST_TEMPLATE.md` — 新建 PR 时自动填充描述。

### 13.3 CODEOWNERS

`.github/CODEOWNERS` — PR 涉及对应路径时自动 request review。

### 13.4 依赖自动更新: Renovate (推荐)

Renovate 的 `pinDigests` 是 SHA 固定机制的关键基础设施。配置 `.github/renovate.json`。

### 13.5 Labeler

`.github/labeler.yml` + `actions/labeler` 自动按文件路径打 label。

---

## 十四、测试策略

OpenCI 测试分四层金字塔:

| 层 | 类型 | 工具 | 覆盖 |
| --- | --- | --- | --- |
| 1 | Unit tests | BATS (shell) + Node.js | 129 tests, 80%+ coverage |
| 2 | Integration tests | pipeline + contract tests | workflow routing, schema validation |
| 3 | Agentic eval | schema validation + live Claude API | skill output quality |
| 4 | Live E2E | self-bootstrapping | real PR + real issue → full pipeline |

### 14.1 Action 级别测试

每个 composite action 和原子 action 使用 bats-core 进行单元测试。

### 14.2 Agentic 测试

- **Offline**: 验证 skill 输出 schema (不调用 API)
- **Live**: 调用 Claude API (Haiku 模型) 验证 issue triage 和 PR review 输出质量
- **Self-bootstrapping E2E**: 创建真实 GitHub issue，观察 OpenCI 自己的 issue-ops pipeline 自主响应

### 14.3 Workflow 级别测试

使用 act 在本地模拟 GitHub Actions 运行，但 act 对 OpenCI 核心能力覆盖有限:

| 功能 | act 支持 |
| --- | --- |
| 跨仓库 reusable workflow | ❌ |
| OIDC + cosign 签名 | ❌ |
| environment 审批门 | ❌ |
| workflow_run 触发器 | ❌ |

act 的定位: 开发者本地快速验证 shell 逻辑。不能替代 CI。

---

## 十五、成本意识

OpenCI 的 AI 步骤按 Claude Sonnet 定价，典型中型团队(50 PR/月)月度成本约 $15。消费方应:启用 prompt caching、对简单任务用 Haiku、为非关键 PR 关闭 `enable-ai-review`。

---

## 十六、EvolveCI 关系

OpenCI 是**通用 CI/CD 基础层**。EvolveCI 是**应用层**——通过 `uses: YiAgent/OpenCI/.github/workflows/reusable-*.yml@v3` 引用 OpenCI，在其上扩展 AI Agent 特化能力。OpenCI 不感知也不依赖 EvolveCI。

---

## 附录 A: SHA 一致性验证脚本

`.github/scripts/verify-sha-consistency.sh` 职责:

1. 扫描所有 `.github/workflows/*.yml` 与 `actions/**/*.yml` 中的 `uses: <action>@<SHA>` 行
2. 比对每条引用的 SHA 与 `manifest.yml` 的 `deps:` 段，不一致则 `exit 1`
3. 拒绝 `@v*` / `@main` / `@master` 形式的 tag/branch 引用
4. 拒绝 `manifest-pending.yml` 中的条目被实际使用
