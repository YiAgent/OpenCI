# OpenCI 项目完整设计规格文档

> 版本：v1.0  
> 用途：可直接交给 Claude Code 实施的完整设计规格  
> 仓库定位：公开 GitHub 仓库，供自己多个项目及外部项目通过 `uses:` 引用

---

## 一、项目概述与设计原则

### 1.1 项目定位

本仓库是一个 **GitHub Actions 共享库**，提供三层可复用单元：

- **主工作流（Reusable Workflow）**：完整的阶段流水线，调用方一行引入
- **Composite Action**：阶段内的组合逻辑，封装多个原子
- **原子 Action**：最小职责单元，单一功能，明确输入输出

所有涉及 AI 的步骤统一通过 `claude-harness.yml` 执行，不直接在各 action 中调用 Claude API。

### 1.2 四条设计原则

**原则一：变化频率决定位置**  
Prompt 独立于 Action 存放，因为两者变化频率不同。Action 结构数月不变，Prompt 每周调优。Scripts 跟随调用它的 Action，不集中存放，除非被两个以上 Action 复用才提到 `lib/`。

**原则二：命名即语义**  
Action 命名格式：`动词-名词`（`lint-node`、`scan-deps`、`tag-release`）。目录命名格式：名词（`issue`、`pr`、`stg`、`prd`）。Composite 与原子同在阶段目录下，通过名称复杂度区分粒度，不单独建 `composites/` 目录。

**原则三：调用层级单向**  
主工作流调用 Composite，Composite 调用原子，原子不互相调用。AI 原子统一向上调用 `claude-harness.yml`，不直接调用 Claude API。

**原则四：外部优于自实现**  
有成熟的 Verified Creator action 时，优先封装使用，不重复造轮子。自实现仅用于：无现成方案、命令因项目而异（build/test/deploy）、业务规则特定（slash command、smoke-test）。

---

## 二、完整目录结构

```
shared-actions/
│
├── .github/
│   └── workflows/                          # 公共 API 层（对外暴露的入口）
│       ├── claude-harness.yml              # AI 执行引擎（thin wrapper over anthropics/claude-code-action）
│       ├── issue.yml                       # Issue 生命周期主工作流
│       ├── issue-comment.yml               # Issue 评论 slash 命令处理
│       ├── stale.yml                       # 定时 Stale 清理
│       ├── pr.yml                          # PR 统一工作流（自动检测语言，合并原 pr-node/nextjs/python/java）
│       ├── stg.yml                         # Staging 部署验证工作流
│       └── prd.yml                         # Production 发布工作流（含人工审批）
│
├── actions/                                # 实现层
│   ├── _common/                            # 跨阶段通用原子（无阶段归属）
│   │   ├── setup-node/
│   │   │   └── action.yml
│   │   ├── setup-python/
│   │   │   └── action.yml
│   │   ├── setup-java/
│   │   │   └── action.yml
│   │   ├── post-comment/                   # sticky 评论（github-script + standalone JS）
│   │   │   ├── action.yml
│   │   │   └── post-comment.js
│   │   ├── notify/                         # 通知统一入口（Slack/钉钉）
│   │   │   └── action.yml
│   │   └── upload-coverage/               # 覆盖率上报（Codecov）
│   │       └── action.yml
│   │
│   ├── issue/                              # Issue 阶段
│   │   ├── validate/                       # 模板完整性校验 [Composite]
│   │   │   └── action.yml
│   │   ├── classify-label/                 # 分类打标签 [Composite: 纯 AI]
│   │   │   └── action.yml
│   │   ├── route/                          # 分配负责人 + 加 Project Board [Composite]
│   │   │   └── action.yml
│   │   ├── duplicate-check/               # AI 重复检测 [原子]
│   │   │   └── action.yml
│   │   ├── agent-analyze/                  # AI 深度分析并评论 [原子]
│   │   │   └── action.yml
│   │   ├── parse-command/                  # slash 命令解析 [原子]
│   │   │   └── action.yml
│   │   └── execute-command/               # slash 命令执行 [原子]
│   │       └── action.yml
│   │
│   ├── pr/                                 # PR 阶段
│   │   ├── quality-gate/                  # 质量门 [Composite，语言自适应]
│   │   │   └── action.yml
│   │   ├── lint-node/                     # ESLint + Prettier [原子]
│   │   │   └── action.yml
│   │   ├── lint-python/                   # Ruff lint + format check [原子]
│   │   │   └── action.yml
│   │   ├── lint-java/                     # Checkstyle + SpotBugs [原子]
│   │   │   └── action.yml
│   │   ├── typecheck-ts/                  # tsc --noEmit [原子]
│   │   │   └── action.yml
│   │   ├── typecheck-python/              # mypy [原子]
│   │   │   └── action.yml
│   │   ├── test-node/                     # Jest/Vitest + coverage [原子]
│   │   │   └── action.yml
│   │   ├── test-python/                   # pytest + coverage [原子]
│   │   │   └── action.yml
│   │   ├── test-java/                     # Maven/Gradle test [原子]
│   │   │   └── action.yml
│   │   ├── check-coverage/               # 覆盖率阈值检查，语言无关 [原子]
│   │   │   └── action.yml
│   │   ├── test-report/                   # 测试报告渲染 [原子]
│   │   │   └── action.yml
│   │   ├── scan-deps/                     # 依赖漏洞扫描 [原子]
│   │   │   └── action.yml
│   │   ├── scan-secrets/                  # Secret 泄漏检测 [原子]
│   │   │   └── action.yml
│   │   ├── pr-title-check/               # Conventional Commits 标题校验 [原子]
│   │   │   └── action.yml
│   │   ├── size-label/                    # PR 大小标签 XS/S/M/L/XL [原子]
│   │   │   └── action.yml
│   │   ├── build-node/                    # tsc 编译验证 [原子]
│   │   │   └── action.yml
│   │   ├── build-java/                    # mvn package 验证 [原子]
│   │   │   └── action.yml
│   │   └── agent-review/                  # AI 代码 Review [原子] → claude-harness
│   │       └── action.yml
│   │
│   ├── stg/                               # Staging 阶段
│   │   ├── deploy/                        # 部署原子（平台参数化）
│   │   │   └── action.yml
│   │   ├── health-check/                  # 等待服务就绪轮询
│   │   │   └── action.yml
│   │   ├── smoke-test/                    # 冒烟测试
│   │   │   └── action.yml
│   │   ├── agent-diagnose/               # 失败时 AI 诊断 → claude-harness
│   │   │   └── action.yml
│   │   └── rollback/                      # 回滚
│   │       └── action.yml
│   │
│   └── prd/                               # Production 阶段
│       ├── deploy/                        # 生产部署
│       │   └── action.yml
│       ├── tag-release/                   # 自动打版本 tag
│       │   └── action.yml
│       ├── create-release/               # 创建 GitHub Release
│       │   └── action.yml
│       ├── agent-release-notes/          # AI 生成 Release Notes → claude-harness
│       │   └── action.yml
│       └── rollback/                      # 生产回滚
│           └── action.yml
│
├── prompts/                               # Prompt 层（独立于 action 变化）
│   ├── issue/
│   │   ├── triage.md                      # Issue 分类，返回 JSON，适用 sonnet
│   │   ├── triage.haiku.md               # 轻量版，速度优先，适用 haiku
│   │   └── duplicate-check.md            # 重复检测，返回 JSON
│   ├── pr/
│   │   ├── code-review.md                # 全面 review，返回 JSON
│   │   └── code-review.security.md       # 安全专项 review 变体
│   ├── stg/
│   │   └── diagnose-failure.md           # 读 log，返回根因分析 JSON
│   └── prd/
│       └── release-notes.md              # 读 commits/PR，生成 Markdown changelog
│
└── configs/                               # 配置层
    ├── stale/
    │   ├── default.yml                    # 60天/14天标准配置
    │   └── fast.yml                       # 30天/7天快节奏配置
    └── assign-matrix/
        └── default.yml                    # label → team/person 映射矩阵
```

---

## 三、主工作流层详细规格

### 3.1 claude-harness.yml

**定位**：通用 AI 执行引擎，所有 AI 相关 action 的唯一入口。`anthropics/claude-code-action@v1` 的薄封装，不重复实现 CLI 调用、重试、超时等逻辑。

**触发**：`on: workflow_call`

**Job 设计**（单 job）：

```
Job: run-claude
  steps:
    - uses: actions/checkout@v4
    - uses: anthropics/claude-code-action@v1
      with:
        anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}
        github_token: ${{ secrets.GITHUB_TOKEN }}
        model: ${{ inputs.model }}
        max_turns: ${{ inputs.max-turns }}
        timeout_minutes: ${{ inputs.timeout-minutes }}
        allowed_tools: ${{ inputs.allowed-tools }}
        mcp_config: ${{ inputs.mcp-config }}
        plugins: ${{ inputs.plugins }}
        permissions: ${{ inputs.permissions }}
        prompt: ${{ inputs.prompt || format('{0}{1}', '# Task\n\nRead the prompt file: ', inputs.prompt-file) }}
        output_format: ${{ inputs.output-format }}
      id: claude
    - if: inputs.post-comment == 'true'
      uses: actions/_common/post-comment
      with:
        github-token: ${{ secrets.GITHUB_TOKEN }}
        issue-number: ${{ inputs.comment-number }}
        body: ${{ steps.claude.outputs.result }}
        header: openci-claude
```

**inputs 完整规格**：

| 参数名 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| prompt | string | '' | 内联 prompt，与 prompt-file 二选一 |
| prompt-file | string | '' | 仓库内 prompt 文件路径（调用方读取后传入 prompt） |
| model | string | claude-sonnet-4-6 | 模型选择 |
| max-turns | number | 10 | 最大 agent 轮次，1 = 单次问答 |
| timeout-minutes | number | 15 | 超时时间 |
| allowed-tools | string | '' | 逗号分隔，如 Bash,Read,Edit,mcp__github |
| mcp-config | string | '{}' | MCP server 配置 JSON 字符串（调用方传完整 JSON） |
| plugins | string | '' | 官方插件列表，逗号分隔（如 @anthropic-ai/plugin-github） |
| permissions | string | 'read' | 权限级别：read（默认）或 write（opt-in） |
| output-format | string | json | text 或 json |
| post-comment | boolean | false | 是否将结果评论到 PR/Issue |
| comment-number | number | 0 | PR 或 Issue 编号 |

**secrets**：`ANTHROPIC_API_KEY`（required）、`GITHUB_TOKEN`（optional）

**outputs**：`result`、`result-json`、`success`、`exit-code`、`tokens-used`、`cost-usd`、`session-id`（均来自 anthropics/claude-code-action 的 outputs）

---

### 3.2 issue.yml

**触发**：`on: issues: types: [opened]`

**Jobs 链路**：

```
validate（必须最先，失败时 continue: false，阻断后续所有 job）
    ↓ 通过
classify-label  ←→  duplicate-check（两者并行，互不依赖）
    ↓ 两者都完成
route（depends: classify-label + duplicate-check）
    ↓
agent-analyze（depends: route，仅 inputs.enable-ai == 'true'）
```

**Job: validate**
- 调用：`actions/issue/validate`
- 失败时：打 `needs-more-info` 标签，评论模板引导，`continue: false`

**Job: classify-label**
- 调用：`actions/issue/classify-label`
- outputs：`type`（bug/feature/question/docs/security）、`area`（frontend/backend/infra）、`confidence`

**Job: duplicate-check**
- 调用：`actions/issue/duplicate-check`
- 若发现重复：评论关联 issue，打 `duplicate` 标签，关闭当前 issue
- outputs：`is-duplicate`、`duplicate-of`

**Job: route**
- if: `needs.duplicate-check.outputs.is-duplicate != 'true'`
- 调用：`actions/issue/route`

**Job: agent-analyze**
- if: `inputs.enable-ai == 'true' && needs.route.result == 'success'`
- 调用：`actions/issue/agent-analyze`

**inputs**：`enable-ai`（boolean，default: true）、`model`（default: claude-haiku-4-5-20251001）、`assign-matrix-path`（default: configs/assign-matrix/default.yml）

**secrets**：`ANTHROPIC_API_KEY`、`GITHUB_TOKEN`

---

### 3.3 issue-comment.yml

**触发**：`on: issue_comment: types: [created]`

**Jobs 链路**：

```
parse-command（识别评论是否包含 slash 指令，检查发起人权限）
    ↓ 识别到指令且有权限
execute-command（根据指令类型分支执行）
```

**支持的 slash 指令**：`/assign @user`、`/unassign @user`、`/label <name>`、`/remove-label <name>`、`/close`、`/reopen`、`/milestone <title>`、`/ask <question>`

**权限检查**：评论者必须是仓库 collaborator 或 member，否则静默忽略。用 `actions/github-script@v7` 调用 API 检查。

**`/ask` 特殊处理**：
- 调用 `claude-harness.yml`
- skill: `issue-triager`
- prompt: issue 完整内容 + 问题
- post-comment: true（sticky 更新同一条评论）

**secrets**：`ANTHROPIC_API_KEY`（仅 /ask 需要）、`GITHUB_TOKEN`

---

### 3.4 stale.yml

**触发**：`on: schedule: - cron: '0 2 * * *'`

**Jobs**：

```
Job: manage-stale
  - uses: actions/stale@v9，配置：
    - days-before-stale: 60
    - days-before-close: 14
    - stale-issue-label: stale
    - stale-issue-message: 模板评论（提示即将关闭）
    - exempt-issue-labels: pinned,security,confirmed-bug,in-progress
    - close-issue-message: 模板评论（已关闭原因）

Job: lock-resolved（depends: manage-stale）
  - uses: dessant/lock-threads@v5
    关闭后 7 天自动锁定，防止继续评论
```

**inputs**：`stale-days`（default: 60）、`close-days`（default: 14）、`exempt-labels`（default: pinned,security）

---

### 3.5 pr.yml

**定位**：单一 PR 工作流，自动检测语言，替代原 pr-node/pr-nextjs/pr-python/pr-java 四个工作流。

**触发**：`on: pull_request`（types: opened, synchronize, reopened）

**Jobs 链路**：

```
detect-language → setup → quality-gate → (parallel: security) → agent-review → notify
```

**inputs 完整规格**：

| 参数名 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `language` | string | `'auto'` | 项目语言，auto 时自动检测 |
| `node-version` | string | `'20'` | Node.js 版本 |
| `python-version` | string | `'3.11'` | Python 版本 |
| `java-version` | string | `'17'` | Java 版本 |
| `package-manager` | string | `''` | 包管理器，空则按语言选默认值 |
| `test-command` | string | `''` | 测试命令，空则按语言选默认值 |
| `coverage-threshold` | number | `80` | 覆盖率阈值 |
| `enable-agent-review` | boolean | `true` | 是否启用 AI review |
| `working-directory` | string | `'.'` | 工作目录 |
| `slack-channel` | string | `''` | Slack 通知频道 |

**secrets**：`ANTHROPIC_API_KEY`、`GITHUB_TOKEN`、`SLACK_WEBHOOK`

**outputs**：`quality-passed`（bool）、`coverage-pct`（number）、`language`（string）

**语言检测逻辑**：`package.json` → node，`pyproject.toml` → python，`pom.xml` → java，均不存在 → fail

各语言默认值：node → pnpm / `pnpm test`，python → uv / `uv run pytest`，java → maven / `mvn test`

---

### 3.6 stg.yml

**触发**：`on: workflow_call`（CI 构建成功后自动触发）或 `workflow_dispatch`

**Jobs 链路**：

```
build-image（docker 四件套）
    ↓
deploy（调用 actions/stg/deploy）
    ↓
verify（health-check + smoke-test）
    ↓ 若 verify 失败
diagnose（调用 actions/stg/agent-diagnose → claude-harness）
    ↓ 若 rollback-on-failure == 'true'
rollback（调用 actions/stg/rollback）
    ↓
notify（if: always()）
```

**inputs**：`image-tag`（required）、`deploy-command`（required）、`smoke-test-urls`（逗号分隔）、`health-check-url`、`rollback-on-failure`（boolean，default: true）、`environment`（default: staging）

**secrets**：`DEPLOY_KEY`、`ANTHROPIC_API_KEY`、`SLACK_WEBHOOK`、`GITHUB_TOKEN`

---

### 3.7 prd.yml

**触发**：`on: workflow_dispatch`（手动触发，必须指定 version）

**Jobs 链路**：

```
pre-check（验证 stg 已通过，检查 stg deployment status）
    ↓
release-notes（调用 actions/prd/agent-release-notes → claude-harness，创建 Release 草稿）
    ↓
approval-gate（GitHub Environment: production，人工审批门，默认 required reviewers）
    ↓ 审批通过
deploy（调用 actions/prd/deploy，environment: production）
    ↓
post-deploy-verify（smoke-test on production，观察窗口 10 分钟）
    ↓ 若失败
rollback（调用 actions/prd/rollback）
    ↓
post-release（tag-release + create-release + notify）
```

**inputs**：`version`（required，如 v1.2.3）、`deploy-command`（required）、`skip-release-notes`（boolean，default: false）、`canary-pct`（number，default: 0，0 表示直接全量）

**secrets**：`DEPLOY_KEY`、`ANTHROPIC_API_KEY`、`GITHUB_TOKEN`、`SLACK_WEBHOOK`

---

## 四、Composite Action 层详细规格

### 4.1 actions/_common/setup-node

**职责**：Node 环境 + 包管理器 + 依赖缓存一体化封装

**inputs**：

| 参数 | 默认值 | 说明 |
|---|---|---|
| node-version | '20' | Node 版本 |
| package-manager | 'pnpm' | pnpm / npm / yarn |
| working-directory | '.' | 工作目录 |
| install | 'true' | false 时只装环境不装依赖 |

**outputs**：`cache-hit`（bool）

**实现**：

```
steps:
  1. actions/setup-node@v4（官方，node-version 参数）
  2. pnpm/action-setup@v4（仅 package-manager == 'pnpm' 时）
  3. actions/cache@v4（key: node-{node-version}-{pm}-{lockfile-hash}）
  4. {pm} install（if: install == 'true' && cache-hit != 'true'）
```

---

### 4.2 actions/_common/setup-python

**inputs**：`python-version`（default: '3.11'）、`package-manager`（default: 'uv'，支持 uv/poetry/pip）、`working-directory`

**outputs**：`cache-hit`

**实现**：

```
steps:
  1. actions/setup-python@v5（官方）
  2. astral-sh/setup-uv@v5（仅 uv 时）
  3. actions/cache@v4（key: python-{version}-{pm}-{lockfile-hash}）
  4. 按 pm 类型执行安装命令（cache miss 时）
```

---

### 4.3 actions/_common/setup-java

**inputs**：`java-version`（default: '17'）、`distribution`（default: 'temurin'）、`build-tool`（default: 'maven'）

**实现**：

```
steps:
  1. actions/setup-java@v4（官方，cache 参数直接设 build-tool，原生支持 maven/gradle 缓存）
```

---

### 4.4 actions/_common/post-comment

**inputs**：`github-token`（required）、`issue-number`（required）、`body`（required）、`header`（string，sticky 评论的唯一标识 key）

**实现**：`actions/github-script@v7` + 独立 JS 文件 `post-comment.js`（纯 GitHub API 实现 sticky 评论：若 header 相同则更新，不堆叠）

---

### 4.5 actions/_common/notify

**inputs**：`webhook`（secret）、`status`（success/failure/cancelled）、`message`（string）、`channel`（string）

**实现**：`slackapi/slack-github-action@v2`，Block Kit 格式，颜色随 status 变化（green/red/gray）

---

### 4.6 actions/issue/validate（Composite）

**inputs**：`github-token`、`issue-number`、`issue-body`

**outputs**：`valid`（bool）

**实现**：

```
steps:
  1. actions/github-script@v7：
     - 检查 issue-body 是否包含模板的必要 H2 节（复现步骤、期望行为、环境信息）
     - 检查这些节是否有实际内容（非空、非占位符）
  2. if valid == false:
     - 打标签 needs-more-info（github-script）
     - 调用 _common/post-comment 发引导评论
```

---

### 4.7 actions/issue/classify-label（Composite）

**inputs**：`github-token`、`issue-number`、`issue-title`、`issue-body`、`enable-ai`（bool）、`api-key`、`model`

**outputs**：`type`、`area`、`confidence`

**实现**：

```
steps:
  1. 调用 claude-harness.yml，prompt = prompts/issue/triage.md，model: haiku
     返回 JSON {type, area, confidence}
  2. if confidence < 0.7: 打 needs-triage 标签（人工确认），不强行打类型标签
     else: 用 github-script 打对应标签
```

纯 AI 分类，不使用 `actions/labeler@v5`。所有分类逻辑由 AI 完成，减少维护成本。

---

### 4.8 actions/issue/route（Composite）

**inputs**：`github-token`、`issue-number`、`issue-type`、`issue-area`、`matrix-path`（default: configs/assign-matrix/default.yml）

**outputs**：`assignee`

**实现**：

```
steps:
  1. 读取 matrix-path YAML，找 type+area 对应的 assignee/team
  2. actions/github-script@v7：调用 API 分配 assignee
  3. actions/github-script@v7：调用 GraphQL API 加入 GitHub Project Board
```

---

### 4.9 actions/pr/quality-gate-node（Composite）

**inputs**：`node-version`、`package-manager`、`test-command`、`coverage-threshold`、`github-token`、`pr-number`、`working-directory`

**outputs**：`passed`（bool）、`coverage-pct`（number）

**实现**：

```
steps:
  1. actions/checkout@v4
  2. actions/_common/setup-node（with all inputs）
  3. actions/pr/lint-node（with working-directory）
  4. actions/pr/typecheck-ts（with working-directory）
  5. actions/pr/test-node（with test-command, working-directory）id: test-step
  6. actions/pr/check-coverage（with coverage-pct: steps.test-step.outputs.coverage-pct,
     threshold: coverage-threshold, github-token, pr-number）id: coverage-step
  7. actions/pr/test-report（with working-directory）
  8. outputs: passed = steps.coverage-step.outputs.passed,
              coverage-pct = steps.test-step.outputs.coverage-pct
```

`quality-gate-python` 和 `quality-gate-java` 结构相同，替换内部步骤为对应语言的原子。

---

## 五、原子 Action 层完整规格

### 5.1 实现方式说明

每个原子标注以下属性：

- **[官方]**：GitHub 官方出品，直接 uses，不封装
- **[外部]**：Verified Creator 或社区成熟方案，薄封装
- **[自实现]**：用 shell/github-script 实现，无现成方案或命令因项目而异
- **[AI]**：调用 `claude-harness.yml` 实现，传对应 prompt 和 skill

---

### 5.2 _common 层原子

| Action | 实现方式 | 核心实现 |
|---|---|---|
| `_common/post-comment` | [自实现] | `actions/github-script@v7` + 独立 JS 文件 `post-comment.js`，纯 GitHub API 实现 sticky 评论 |
| `_common/notify` | [外部] | `slackapi/slack-github-action@v2` |
| `_common/upload-coverage` | [外部] | `codecov/codecov-action@v5`，公开仓库免费 |

---

### 5.3 issue 层原子

| Action | 实现方式 | 核心实现 |
|---|---|---|
| `issue/duplicate-check` | [AI] | → claude-harness，prompt: prompts/issue/duplicate-check.md，返回 JSON {is_duplicate, duplicate_of, similarity}，model: haiku |
| `issue/agent-analyze` | [AI] | → claude-harness，prompt: prompts/issue/triage.md，post-comment: true，model: sonnet |
| `issue/parse-command` | [自实现] | github-script，正则提取 /command args，检查评论者权限（collaborator/member），outputs: command, args, authorized |
| `issue/execute-command` | [自实现] | github-script 分支：assign/label/close/reopen/milestone → GitHub API；/ask → 调用 claude-harness，skill: issue-triager |

---

### 5.4 pr 层原子

| Action | 实现方式 | 核心实现 |
|---|---|---|
| `pr/lint-node` | [外部] | `reviewdog/action-eslint@v1` + Prettier check（run: pnpm prettier --check .），结果标注到 PR diff |
| `pr/lint-python` | [自实现] | `run: uvx ruff check . && uvx ruff format --check .`，无专用 action |
| `pr/lint-java` | [自实现] | `run: mvn checkstyle:check`（maven）或 `./gradlew checkstyleMain`（gradle）|
| `pr/typecheck-ts` | [自实现] | `run: pnpm tsc --noEmit`，无专用 action，命令因项目而异 |
| `pr/typecheck-python` | [自实现] | `run: uv run mypy .`，同上 |
| `pr/test-node` | [自实现] | `run: {test-command} --coverage`，输出 coverage-pct（从 coverage-summary.json 解析） |
| `pr/test-python` | [自实现] | `run: {test-command} --cov --cov-report=json`，输出 coverage-pct（从 coverage.json 解析） |
| `pr/test-java` | [自实现] | `run: mvn test` 或 `./gradlew test`，输出 surefire XML |
| `pr/check-coverage` | [自实现] | bash 比较 coverage-pct 与 threshold，调用 _common/post-comment 发结果，输出 passed（bool），语言无关 |
| `pr/test-report` | [外部] | `dorny/test-reporter@v1`，支持 JUnit/Jest/pytest XML，渲染为 PR check |
| `pr/scan-deps` | [外部] | `aquasecurity/trivy-action@master`，`--scanners vuln`，扫依赖漏洞，免费开源 |
| `pr/scan-secrets` | [外部] | `gitleaks/gitleaks-action@v2`，扫 secret 泄漏 |
| `pr/pr-title-check` | [外部] | `amannn/action-semantic-pull-request@v5`，Conventional Commits 格式 |
| `pr/size-label` | [外部] | `pascalgn/size-label-action@v0.5.4`，按改动行数打 XS/S/M/L/XL |
| `pr/build-node` | [自实现] | `run: pnpm tsc -p tsconfig.build.json` |
| `pr/build-java` | [自实现] | `run: mvn package -DskipTests` 或 `./gradlew build -x test` |
| `pr/agent-review` | [AI] | → claude-harness，prompt: prompts/pr/code-review.md，allowed-tools: mcp__github，post-comment: true，model: sonnet |

---

### 5.5 stg 层原子

| Action | 实现方式 | 核心实现 |
|---|---|---|
| `stg/deploy` | [自实现] | inputs.deploy-command 参数化，支持 docker run / kubectl apply / fly deploy / render hook |
| `stg/health-check` | [自实现] | bash 轮询：`curl -f {url}`，间隔 10s，最多重试 30 次（5 分钟），超时则 fail |
| `stg/smoke-test` | [自实现] | bash：遍历 inputs.urls，curl 检查状态码，失败时输出具体接口和响应 |
| `stg/agent-diagnose` | [AI] | → claude-harness，prompt: prompts/stg/diagnose-failure.md，传入失败 job 的 log，post-comment: true，model: sonnet |
| `stg/rollback` | [自实现] | docker tag + push（previous-image-tag 从 inputs 传入），或 kubectl rollout undo |

---

### 5.6 prd 层原子

| Action | 实现方式 | 核心实现 |
|---|---|---|
| `prd/deploy` | [自实现] | 同 stg/deploy，但 environment 绑定 production（触发 GitHub Environment 审批） |
| `prd/tag-release` | [外部] | `mathieudutour/github-tag-action@v6`，语义化版本自动递增 |
| `prd/create-release` | [外部] | `softprops/action-gh-release@v2`，创建正式 Release，支持草稿、附件上传 |
| `prd/agent-release-notes` | [AI] | → claude-harness，prompt: prompts/prd/release-notes.md，skill: release-manager，读 git log 和 merged PR 列表，返回 Markdown changelog，model: sonnet |
| `prd/rollback` | [自实现] | git checkout {prev-tag}，重新触发 deploy job |

---

## 六、支撑文件层规格

### 6.1 scripts/lib/ 规范

只有被两个以上 action 引用的脚本才放 lib/，其余脚本放在对应 action 目录的 scripts/ 下。

**lib/github/post-comment.js**：

纯 GitHub API 实现的 sticky 评论逻辑（基于 `actions/github-script@v7`），处理 issue-number 是 PR 还是 Issue 的区分，统一 header 标识策略。已迁移至 `actions/_common/post-comment/post-comment.js`。

---

### 6.2 prompts/ 文件规范

每个 prompt 文件的头部注释格式：

```
# Model: claude-sonnet-4-6          ← 适用模型
# Scene: PR 代码 review，关注逻辑和安全 ← 使用场景
# Output: JSON                        ← 输出格式
```

调用方负责传入完整的 prompt 内容，harness 不做变量替换。

**各 prompt 文件的输出格式约定**：

- `prompts/issue/triage.md`：`{"type":"bug|feature|question|docs|security","area":"frontend|backend|infra|db","priority":"P0|P1|P2|P3","confidence":0.0-1.0,"reasoning":"..."}`
- `prompts/issue/triage.haiku.md`：同上，但 prompt 更简洁，token 更少，牺牲部分准确率换速度
- `prompts/issue/duplicate-check.md`：`{"is_duplicate":bool,"duplicate_of":null|number,"similarity":0.0-1.0,"reason":"..."}`
- `prompts/pr/code-review.md`：`{"issues":[{"file":"","line":0,"severity":"error|warning|suggestion","category":"logic|security|performance|style","description":"","suggestion":""}],"score":0-10,"summary":"","highlights":[]}`
- `prompts/pr/code-review.security.md`：仅返回 security 类别的 issues
- `prompts/stg/diagnose-failure.md`：`{"root_cause":"","confidence":0.0-1.0,"suggestions":[],"related_files":[],"estimated_fix_time":"..."}`
- `prompts/prd/release-notes.md`：Markdown 格式 changelog，分 Breaking Changes / New Features / Bug Fixes / Performance / Internal 分组

---

### 6.3 configs/ 文件规范

**configs/assign-matrix/default.yml**（label → 负责人映射）：

```yaml
matrix:
  - match:
      type: bug
      area: frontend
    assign: [frontend-lead]
  - match:
      type: bug
      area: backend
    assign: [backend-lead]
  - match:
      priority: P0
    assign: [oncall-engineer]
    notify: [engineering-channel]
```

---

## 七、调用方使用示例

### 7.1 最简调用（Node.js 项目）

```yaml
# 调用方仓库 .github/workflows/ci.yml
jobs:
  ci:
    uses: your-name/shared-actions/.github/workflows/pr.yml@v1
    with:
      node-version: '22'
      enable-agent-review: true
    secrets: inherit
```

### 7.2 Python 项目

```yaml
jobs:
  ci:
    uses: your-name/shared-actions/.github/workflows/pr.yml@v1
    with:
      python-version: '3.12'
      package-manager: 'poetry'
      test-command: 'poetry run pytest'
    secrets: inherit
```

### 7.4 Issue 自动化

```yaml
# 调用方仓库 .github/workflows/issue-auto.yml
on:
  issues:
    types: [opened]
jobs:
  triage:
    uses: your-name/shared-actions/.github/workflows/issue.yml@v1
    with:
      enable-ai: true
      model: claude-haiku-4-5-20251001
    secrets: inherit
```

### 7.5 直接调用 AI 引擎（自定义任务）

```yaml
jobs:
  custom-ai-task:
    uses: your-name/shared-actions/.github/workflows/claude-harness.yml@v1
    with:
      model: claude-sonnet-4-6
      max-turns: 1
      allowed-tools: mcp__github
      mcp-config: |
        {"mcpServers":{"github":{"command":"npx","args":["-y","@modelcontextprotocol/server-github"],"env":{"GITHUB_TOKEN":"$GITHUB_TOKEN"}}}}
      prompt: |
        分析 issue #${{ github.event.issue.number }} 并返回优先级 JSON
      output-format: json
      post-comment: false
    secrets:
      ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
      GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

---

## 八、版本管理规范

### 8.1 Tag 策略

发布新版本时同时打三层 tag：

```bash
git tag v1.2.3
git tag -f v1.2
git tag -f v1
git push origin v1.2.3 v1.2 v1 --force
```

调用方按需选择锁定粒度：

```yaml
uses: your-name/shared-actions/.github/workflows/pr.yml@v1        # 跟 minor 更新
uses: your-name/shared-actions/.github/workflows/pr.yml@v1.2      # 锁到 patch
uses: your-name/shared-actions/.github/workflows/pr.yml@v1.2.3    # 完全锁定
```

### 8.2 Breaking Change 规范

major 版本才允许破坏性变更（inputs 重命名、删除、outputs 格式变化）。Minor 版本只新增 inputs（带默认值）。Patch 版本只修 bug。

破坏性变更必须：在 CHANGELOG.md 标注 `BREAKING CHANGE`，提前在 release notes 中说明迁移方式，旧 major tag 维护至少 3 个月。

---

## 九、实施顺序

按依赖关系从底层到顶层实施，避免引用未创建的文件：

**第一批（无依赖，最先创建）**：

1. `configs/stale/` 所有 YAML
2. `configs/assign-matrix/default.yml`
3. `prompts/` 所有 Markdown 文件（含头部注释规范）

**第二批（依赖 prompts，再创建）**：

4. `actions/_common/` 所有 action（setup-node/python/java, post-comment, notify, upload-coverage）
5. `actions/_common/post-comment/post-comment.js`（基于 actions/github-script@v7 的 sticky 评论逻辑）

**第三批（依赖 _common）**：

6. `actions/issue/` 所有原子（validate, classify-label, route, duplicate-check, agent-analyze, parse-command, execute-command）
7. `actions/pr/` 所有原子（lint-*, typecheck-*, test-*, check-coverage, test-report, scan-deps, scan-secrets, pr-title-check, size-label, agent-review）
8. `actions/stg/` 所有原子
9. `actions/prd/` 所有原子

**第四批（依赖所有 action）**：

10. `.github/workflows/claude-harness.yml`（最核心的主工作流）
11. `.github/workflows/issue.yml`
12. `.github/workflows/issue-comment.yml`
13. `.github/workflows/stale.yml`
14. `.github/workflows/pr.yml`（统一 PR 工作流，自动检测语言）
15. `.github/workflows/stg.yml`
16. `.github/workflows/prd.yml`

---

## 十、关键约束（实施时必须遵守）

1. **所有 AI 调用必须走 claude-harness.yml**，严禁在原子 action 中直接调用 Claude API。

2. **MCP 配置文件必须写入 `$RUNNER_TEMP`**，不得写入工作目录，job 结束前必须 `rm -f`。

3. **claude-harness.yml 通过官方 action 的 `permissions` 输入控制权限**，不使用 `--dangerously-skip-permissions`。默认 `read` 权限，需要写入时显式声明 `write`。

4. **`pr/check-coverage` 保持语言无关**，只接受 `coverage-pct` 数字输入，不含任何解析逻辑。各语言 test 原子负责将覆盖率解析并输出为 `coverage-pct`。

5. **所有 sticky 评论使用 `_common/post-comment`**，基于 `actions/github-script@v7` 实现，保证统一的 header 标识策略。

6. **`issue-comment.yml` 必须做权限检查**，评论者不是 collaborator 或 member 时静默退出，防止任意人触发 slash 命令。

7. **`prd.yml` 的 deploy job 必须绑定 `environment: production`**，利用 GitHub Environment Protection Rules 实现人工审批，不用其他方式替代。

8. **外部 action 版本锁定策略**：在 shared-actions 内部调用外部 action 时，锁定到 major 版本（如 `@v4`），调用方调用 shared-actions 时同样锁 major（如 `@v1`）。

9. **self-hosted runner 兼容**：所有 `run:` 步骤使用 `shell: bash`，不依赖 runner 默认 shell。所有工具安装步骤（pnpm、uv 等）在 setup action 内部处理，不假设 runner 预装。

10. **使用官方插件生态**：不自建 skills 目录，通过官方 `anthropics/claude-code-action@v1` 的插件机制扩展能力。MCP 配置由调用方传入完整 JSON 字符串，harness 不做模板替换。
