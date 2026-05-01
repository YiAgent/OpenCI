# OpenCI 项目完整设计规格文档

**版本**：v1.1  
**用途**：可直接交给 Claude Code 实施的完整设计规格  
**仓库定位**：公开 GitHub 仓库，供自己多个项目及外部项目通过 `uses:` 引用

---
 
## 变更日志
 
| 版本 | 变更内容 |
|------|---------|
| v1.1 | 新增 Action Manifest 注册表；语言检测单一来源（`_common/detect-language`）；市场服务深度集成（Codecov / CodeQL / harden-runner）；STG→PRD 强化 pre-check（版本对齐 + 观察窗口）；可观测性 annotation 规范；安全原则独立成第五条 |
| v1.0 | 初始版本 |
 
---
---

## 一、项目概述与设计原则

### 1.1 项目定位
 
本仓库是一个 GitHub Actions 共享库，提供三层可复用单元：
 
| 层级 | 类型 | 引用方式 | 举例 |
|------|------|---------|------|
| 主工作流 | Reusable Workflow | `uses: org/opencl/.github/workflows/pr.yml@v2` | 完整 PR 质量门流水线 |
| Composite Action | 阶段内组合逻辑 | `uses: org/opencl/actions/pr/lint-code@v2` | 调用多个原子的 lint 组合 |
| 原子 Action | 最小职责单元 | `uses: org/opencl/actions/pr/lint-node@v2` | 单一语言 lint |
 
**约束**：所有涉及 AI 的步骤统一通过 `claude-harness.yml` 执行，任何 action 不得直接调用 Claude API。

### 1.2 五条设计原则
 
#### 原则一：变化频率决定位置
 
不同文件的变化频率不同，高频变化的文件不应与低频变化的文件耦合在同一位置。
 
| 文件类型 | 变化频率 | 存放位置 | 说明 |
|---------|---------|---------|------|
| Prompt 文件 | 高（每周调优） | `prompts/{stage}/{task}.md` | 与 action 代码分离 |
| Action 实现 | 中（每月迭代） | `actions/{stage}/{name}/` | 跟随阶段目录 |
| 工作流主干 | 低（季度变更） | `.github/workflows/` | 稳定的编排层 |
| 复用脚本 | 低 | `lib/`（仅 2+ action 共用时） | 默认跟随调用方 action |
| 第三方 SHA | 定期（Renovate 维护） | `manifest.yml` 的 `deps` 节点 | **唯一来源**，不在 action 内硬编码 |
 
#### 原则二：命名即语义
 
名称应在不看注释的情况下表达完整意图。
 
- **Action 命名**：`动词-名词` 格式，动词选自固定词汇表
  | 动词 | 语义 |
  |------|------|
  | `detect-` | 探测/识别 |
  | `lint-` | 静态检查 |
  | `scan-` | 安全扫描 |
  | `test-` | 测试执行 |
  | `build-` | 构建产物 |
  | `check-` | 条件验证（通过/失败） |
  | `deploy-` | 部署到环境 |
  | `notify-` | 发送通知 |
  | `create-` | 创建资源 |
  | `sign-` | 加密签名 |
  | `observe-` | 监控等待 |
  | `verify-` | 交叉验证 |
- **目录命名**：名词，对应流水线阶段：`issue/` `pr/` `ci/` `stg/` `prd/` `security/` `_common/`
- **禁止缩写**：`deps` → `dependencies`（文档层面），但 action 名称保持简短
#### 原则三：调用层级单向
 
```
主工作流（Reusable Workflow）
  └── Composite Action（阶段级）
        └── 原子 Action（单一功能）
              └── （AI 原子专属）→ claude-harness.yml
```
 
- 原子 Action 之间不互相调用
- Composite Action 不调用其他 Composite Action
- 主工作流不直接调用原子 Action（必须经过 Composite）
- `claude-harness.yml` 是唯一可被原子 Action 向上调用的主工作流
#### 原则四：外部优于自实现
 
**决策规则**：
 
```
存在 GitHub Verified Creator action？
  ├── 是 → 封装使用，输入输出适配，不修改其行为
  └── 否 → 以下情况自实现：
       ├── 命令因项目而异（build / test / deploy 命令）
       ├── 业务规则特定（slash command 解析、smoke test 路径）
       └── 无现成方案覆盖（如 prompt 版本推送到 Langfuse）
```
 
**反模式**：不得自实现 Docker 构建、secret 扫描、代码覆盖率上报等有成熟方案的功能。
 
#### 原则五：安全默认（v1.1 新增）
 
- **SHA 固定**：所有第三方 action 引用必须使用 commit SHA，而非版本 tag（tag 可被强制覆盖）
- **SHA 集中**：所有 SHA 维护在 `manifest.yml` 的 `deps` 节点，不在 action 文件内硬编码
- **权限最小化**：每个 job 声明 `permissions`，仅开放必要权限
- **harden-runner**：所有工作流每个 job 第一步统一加载，审计出站网络连接
- **OIDC 优先**：认证方式优先使用 OIDC（id-token），避免长期凭证
---

### 1.3 Action Manifest（Action 注册表）

仓库根目录的 `action-manifest.yml` 是所有 action 的元数据注册表，单一来源。

**用途**：

- 自动生成 `docs/ACTIONS.md` 参考文档
- CI 中校验 manifest 与实际 `action.yml` 的一致性（`scripts/validate-manifest.py`）
- 新 contributor 一眼看到全貌：有哪些 action、每个的 input/output 是什么

**字段规范**：

- `version`：manifest 格式版本（当前 `"1.0"`）
- `actions`：按阶段分组（`_common` / `issue` / `pr` / `stg` / `prd`）
- 每个 action 条目包含：
  - `description`：一句话说明
  - `inputs`：`name → {type, required, default, description}`
  - `outputs`：`name → {type, description}`
  - `implementation`：`官方` | `外部` | `自实现` | `AI`
  - `external-action`：（仅 `外部` 类型）引用的第三方 action 及版本
  - `tags`：分类标签数组

**CI 校验**：`scripts/validate-manifest.py` 遍历 `actions/*/action.yml`，对比 manifest 条目与实际 inputs/outputs，不一致则 fail（硬门控）。

**文档生成**：`scripts/generate-action-docs.py` 从 manifest 生成 `docs/ACTIONS.md`，Markdown 表格格式，按阶段分组。

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
│       ├── ci.yml                          # Merge-to-main CI（build image → GHCR → integration test → trivy → cosign → migration dry-run）
│       ├── stg.yml                         # Staging 部署验证工作流（由 ci.yml 调用，使用同一 image）
│       ├── prd.yml                         # Production 发布工作流（由 stg.yml 调用，含 approval-gate + 观察窗口）
│       └── prd-canary-watch.yml            # 生产定时巡检（Sentry 错误率 + health 端点，异常自动 rollback）
│
├── action-manifest.yml                      # Action 注册表（所有 action 的 inputs/outputs 元数据）
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
│   │   ├── harden-runner/                  # Runner 安全加固 [外部]
│   │   │   └── action.yml
│   │   ├── notify/                         # 通知统一入口（Slack/钉钉）
│   │   │   └── action.yml
│   │   ├── upload-coverage/               # 覆盖率上报（Codecov）
│   │   │   └── action.yml
│   │   ├── detect-language/                # 语言/变更区域检测 [原子]
│   │   │   └── action.yml
│   │   ├── paths-filter/                  # 路径变更检测 [外部]
│   │   │   └── action.yml
│   │   ├── opencommit/                     # AI commit message 生成 [外部]
│   │   │   └── action.yml
│   │   └── annotate/                       # 统一遥测 annotation [原子]
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
│   │   ├── mega-lint/                     # MegaLinter 统一 lint [外部]（替代 lint-node/python/java）
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
│   │   ├── scan-secrets/                  # Secret 泄漏检测 [外部]（trufflehog）
│   │   │   └── action.yml
│   │   ├── scan-code/                     # CodeQL 代码安全扫描 [外部]
│   │   │   └── action.yml
│   │   ├── scorecard/                     # OpenSSF Scorecard 供应链安全 [外部]
│   │   │   └── action.yml
│   │   ├── pr-title-check/               # Conventional Commits 标题校验 [外部]
│   │   │   └── action.yml
│   │   ├── size-label/                    # PR 大小标签 XS/S/M/L/XL [外部]
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
│       ├── pre-check/                     # STG→PRD 发布前验证 [自实现]
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
├── configs/                               # 配置层
│   ├── stale/
│   │   ├── default.yml                    # 60天/14天标准配置
│   │   └── fast.yml                       # 30天/7天快节奏配置
│   └── assign-matrix/
│       └── default.yml                    # label → team/person 映射矩阵
│
├── scripts/
│   ├── validate-manifest.py               # Manifest 一致性校验
│   └── generate-action-docs.py            # 从 manifest 生成文档
│
└── docs/
    └── ACTIONS.md                         # 自动生成的 Action 参考文档
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

**语言检测逻辑**：由 `_common/detect-language` action 统一实现（见 4.6 节），pr.yml 通过调用该 action 获取 `language`、`package-manager`、`test-command` 等 outputs。单一来源，不在此重复维护。

---

### 3.6 ci.yml

**定位**：Merge-to-main CI 流水线，构建单一 image 并通过所有验证，作为 stg/prd 部署的唯一 image 来源。

**触发**：`on: push: branches: [main]`（PR merge 后自动触发）

**Jobs 链路**：

```
cleanup（删除已合并分支、关闭关联 issue）
    ↓
build（docker build → push GHCR，输出 image-digest）
    ↓
integration-test（使用刚构建的 image 跑集成测试）
    ↓ 并行
trivy-image-scan（trivy 扫描镜像漏洞 + secret + misconfig）
    ↓
cosign-sign（对 GHCR image 进行 cosign 签名）
    ↓
migration-dry-run（数据库 migration 验证，不实际执行）
    ↓ 全部通过
stg.yml（workflow_call，传入 image-digest）
```

**inputs**（对外暴露，供调用方覆盖）：

| 参数名 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `image-registry` | string | `ghcr.io` | 容器镜像仓库 |
| `integration-test-command` | string | `''` | 集成测试命令，空则按语言选默认值 |
| `trivy-severity` | string | `CRITICAL,HIGH` | Trivy 扫描严重级别 |
| `migration-dir` | string | `'migrations'` | migration 文件目录 |
| `cosign-repository` | string | `''` | cosign 签名目标仓库，空则用 image-registry |

**secrets**：`GITHUB_TOKEN`（GHCR push + cosign）、`COSIGN_PRIVATE_KEY`（cosign 签名）、`DATABASE_URL`（migration dry-run）

**outputs**：`image-digest`（string，如 `ghcr.io/org/app@sha256:abc123`）、`image-tag`（string）、`ci-passed`（bool）

**关键约束**：
- image 使用 `sha256` digest 传递，不用 mutable tag，确保 stg/prd 部署的 image 与 ci 构建的完全一致
- cosign 签名使用 keyless 模式（GitHub OIDC），不需要手动管理密钥
- migration dry-run 使用 `--dry-run` 标志，只验证 SQL 语法和约束，不实际修改数据库

---

### 3.7 stg.yml

**触发**：`on: workflow_call`（由 ci.yml 调用，传入 image-digest）

**Jobs 链路**：

```
migrate（调用 database migration action，使用 image-digest 对应的 SQL）
    ↓
deploy（调用 actions/stg/deploy，使用 GHCR image-digest 部署）
    ↓
verify（health-check + smoke-test）
    ↓ 若 verify 失败
diagnose（调用 actions/stg/agent-diagnose → claude-harness）
    ↓ 若 rollback-on-failure == 'true'
rollback（调用 actions/stg/rollback）
    ↓
notify（if: always()）
    ↓ 全部通过
prd.yml（workflow_call，自动触发 PRD 发布流程）
```

**inputs**：

| 参数 | 类型 | 必填 | 默认值 | 说明 |
|------|------|------|--------|------|
| image-digest | string | yes | — | GHCR image digest（如 `ghcr.io/org/app@sha256:abc123`），由 ci.yml 传入 |
| deploy-command | string | yes | — | 部署命令 |
| migration-dir | string | no | `migrations/` | 数据库迁移脚本目录 |
| database-url | string | no | — | 数据库连接 URL（从 secrets 读取） |
| smoke-test-urls | string | no | — | 逗号分隔的 smoke test URL |
| health-check-url | string | no | — | 健康检查 URL |
| rollback-on-failure | boolean | no | `true` | verify 失败时自动回滚 |
| environment | string | no | `staging` | 部署环境名称 |

**outputs**：

| 参数 | 类型 | 说明 |
|------|------|------|
| stg-passed | boolean | STG 全部验证通过 |
| deployment-id | string | GitHub Deployment ID |
| deployed-at | string | 部署完成时间 ISO8601 |

**secrets**：`DEPLOY_KEY`、`DATABASE_URL`、`ANTHROPIC_API_KEY`、`SLACK_WEBHOOK`、`GITHUB_TOKEN`

---

### 3.8 prd.yml

**触发**：`on: workflow_call`（由 stg.yml 自动调用，传入 image-digest 和 version）

**Jobs 链路**：

```
pre-check（调用 actions/prd/pre-check，四项验证全部通过才放行）：
  1. 版本对齐：STG 最新 deployment 的 SHA/tag == 当前要发布的 version
  2. Smoke test 结果：STG deployment 关联的 smoke-test job conclusion == success
  3. 观察窗口：STG deployment.created_at 距今 >= min-observation-hours（默认 24h）
  4. Canary watch 状态：prd-canary-watch 最近一次 run 无 failure（warn-only，不 block）
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

**inputs**：

| 参数 | 类型 | 必填 | 默认值 | 说明 |
|------|------|------|--------|------|
| image-digest | string | yes | — | GHCR image digest，由 stg.yml 传入，确保 STG 和 PRD 部署同一镜像 |
| version | string | yes | — | 版本 tag（如 v1.2.3） |
| deploy-command | string | yes | — | 部署命令 |
| skip-release-notes | boolean | no | `false` | 跳过 AI 生成 release notes |
| canary-pct | number | no | `0` | Canary 流量百分比，0 表示直接全量 |
| min-observation-hours | number | no | `24` | STG 部署后最小观察窗口（小时） |
| force-skip-observation | boolean | no | `false` | 紧急发布时跳过观察窗口检查 |

**outputs**：

| 参数 | 类型 | 说明 |
|------|------|------|
| prd-passed | boolean | PRD 发布全部通过 |
| release-url | string | GitHub Release URL |
| released-at | string | 发布完成时间 ISO8601 |

**关键约束**：
- approval-gate 通过 GitHub Environment Protection Rules 实现（`environment: production`），不需要单独的 workflow_dispatch 触发
- image-digest 从 ci.yml → stg.yml → prd.yml 全链路传递，确保 STG 和 PRD 部署的是完全相同的镜像
- pre-check 四项验证全部通过后才进入 approval-gate

**secrets**：`DEPLOY_KEY`、`ANTHROPIC_API_KEY`、`GITHUB_TOKEN`、`SLACK_WEBHOOK`

---

### 3.9 prd-canary-watch.yml

**触发**：`on: schedule`（定时巡检，如每 10 分钟）+ `on: workflow_dispatch`（手动触发）

**职责**：生产环境持续巡检，异常时自动触发 rollback。

**Jobs 链路**：

```
watch（定时执行）：
  1. 查询 Sentry 错误率（最近 10 分钟）
  2. 调用 health 端点验证可用性
  3. 对比基线阈值
    ↓ 若异常
notify（发送 Slack 告警）
    ↓ 若 auto-rollback == true
rollback（调用 actions/prd/rollback）
```

**inputs**：

| 参数 | 类型 | 必填 | 默认值 | 说明 |
|------|------|------|--------|------|
| health-url | string | yes | — | 生产环境健康检查 URL |
| sentry-project | string | no | — | Sentry 项目 slug |
| error-rate-threshold | number | no | `0.05` | 错误率阈值（5%） |
| auto-rollback | boolean | no | `false` | 异常时自动回滚 |
| check-interval-minutes | number | no | `10` | 检查间隔（分钟） |

**secrets**：`SENTRY_AUTH_TOKEN`、`SLACK_WEBHOOK`、`DEPLOY_KEY`

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

### 4.6 actions/_common/detect-language

**职责**：语言检测 + 变更区域检测，作为所有 workflow 和 composite action 的单一来源。

**inputs**：

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| language | string | 'auto' | 手动指定语言，auto 时自动检测 |
| working-directory | string | '.' | 检测起始目录 |

**outputs**：

| 参数 | 类型 | 说明 |
|------|------|------|
| language | string | 检测结果：node / python / java / go / rust |
| package-manager | string | 对应包管理器：pnpm / uv / maven / cargo |
| test-command | string | 默认测试命令 |
| lint-command | string | 默认 lint 命令 |
| has-backend | boolean | 是否存在后端代码文件 |
| has-frontend | boolean | 是否存在前端代码文件 |

**语言检测优先级**：

1. `language != 'auto'` → 直接使用
2. 存在 `package.json` → node
3. 存在 `pyproject.toml` 或 `requirements.txt` → python
4. 存在 `pom.xml` 或 `build.gradle` → java
5. 存在 `go.mod` → go
6. 存在 `Cargo.toml` → rust
7. 均不存在 → fail with clear error

**各语言默认值**：

| 语言 | package-manager | test-command | lint-command |
|------|----------------|--------------|--------------|
| node | pnpm | `pnpm test` | `pnpm lint` |
| python | uv | `uv run pytest` | `uvx ruff check .` |
| java | maven | `mvn test` | `mvn checkstyle:check` |
| go | go | `go test ./...` | `golangci-lint run` |
| rust | cargo | `cargo test` | `cargo clippy` |

**变更区域检测**（供 pr-gate.yml 使用）：

- `has-backend`：存在 `app/|src/|lib/|cmd/|internal/|*.go|*.py|*.rs|requirements|pyproject|go.mod|Cargo.toml`
- `has-frontend`：存在 `frontend/|client/|pages/|components/|*.tsx|*.ts|*.jsx|*.js|package.json`

**消费方**：

- `pr.yml`：读取 language/package-manager/test-command 选择质量门子步骤
- `pr-gate.yml`：读取 has-backend/has-frontend 填入 gate-context
- `quality-gate` composite：读取 language 选择 lint/test/typecheck 原子
- `reusable-verify.yml`：读取 language 决定跑哪些 verify job

---

### 4.7 actions/_common/annotate

**职责**：统一遥测 annotation 入口，向多个后端发送部署/发布事件。

**inputs**：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| service | string | yes | 后端：sentry / axiom / datadog / posthog |
| event | string | yes | 事件类型：deploy-start / deploy-success / deploy-failure / release |
| environment | string | yes | 环境：staging / production |
| version | string | yes | 版本 tag 或 SHA |
| trace-id | string | no | 跨 workflow 关联 ID（由 pr-gate 生成 UUID，写入 gate-context） |
| metadata | string | no | 额外 JSON 元数据 |

**实现**：[自实现]，按 service 分支调用各后端 API。

**trace-id 传递**：`pr.yml` 的 detect-language step 生成 trace-id（UUID），写入 gate-context。所有下游 workflow 从 gate-context 读取 trace-id，annotation 中携带以实现跨 workflow 关联查询。

---

### 4.8 actions/issue/validate（Composite）

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

### 4.9 actions/issue/classify-label（Composite）

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

### 4.10 actions/issue/route（Composite）

**inputs**：`github-token`、`issue-number`、`issue-type`、`issue-area`、`matrix-path`（default: configs/assign-matrix/default.yml）

**outputs**：`assignee`

**实现**：

```
steps:
  1. 读取 matrix-path YAML，找 type+area 对应的 assignee/team
  2. actions/github-script@v7：调用 API 分配 assignee
  3. actions/add-to-project@v1：GitHub 官方 Project Board 集成（替代自实现 GraphQL）
```

---

### 4.11 actions/pr/quality-gate-node（Composite）

**inputs**：`node-version`、`package-manager`、`test-command`、`coverage-threshold`、`github-token`、`pr-number`、`working-directory`

**outputs**：`passed`（bool）、`coverage-pct`（number）

**实现**：

```
steps:
  1. actions/checkout@v4
  2. actions/_common/harden-runner（安全加固，每个 workflow 第一步）
  3. actions/_common/setup-node（with all inputs）
  4. actions/pr/mega-lint（with working-directory，替代 lint-node/python/java）
  5. actions/pr/typecheck-ts（with working-directory）
  6. actions/pr/test-node（with test-command, working-directory）id: test-step
  7. actions/pr/check-coverage（with coverage-pct: steps.test-step.outputs.coverage-pct,
     threshold: coverage-threshold, github-token, pr-number）id: coverage-step
  8. actions/pr/test-report（with working-directory）
  9. outputs: passed = steps.coverage-step.outputs.passed,
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
| `_common/harden-runner` | [外部] | `step-security/harden-runner@v2`，Runner 安全加固。阻止未授权网络访问、监控文件系统变化、审计所有命令执行。每个 workflow 的第一个 step 必须调用 |
| `_common/post-comment` | [自实现] | `actions/github-script@v7` + 独立 JS 文件 `post-comment.js`，纯 GitHub API 实现 sticky 评论 |
| `_common/notify` | [外部] | `slackapi/slack-github-action@v2` |
| `_common/upload-coverage` | [外部] | `codecov/codecov-action@v5`，公开仓库免费 |
| `_common/paths-filter` | [外部] | `dorny/paths-filter@v3`，检测哪些路径有变更，输出 boolean 矩阵。后续 job 按需执行，节省 30-50% CI 时间。替代已被攻击的 `tj-actions/changed-files` |
| `_common/opencommit` | [外部] | `di-sukharev/opencommit@v3`，AI 生成 Conventional Commits 格式的 commit message。分析 staged diff，自动生成语义化 message。支持 pre-commit hook 和 CI 模式 |

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
| `pr/mega-lint` | [外部] | `oxsecurity/metalinter@v8`，统一 lint 所有语言（替代 lint-node/python/java）。内置 50+ linter：ESLint、Ruff、Checkstyle、golangci-lint、clippy 等。支持 PR comment 标注、SARIF 上传、AI 辅助修复。outputs: `has_lint_errors` |
| `pr/typecheck-ts` | [自实现] | `run: pnpm tsc --noEmit`，无专用 action，命令因项目而异 |
| `pr/typecheck-python` | [自实现] | `run: uv run mypy .`，同上 |
| `pr/test-node` | [自实现] | `run: {test-command} --coverage`，输出 coverage-pct（从 coverage-summary.json 解析） |
| `pr/test-python` | [自实现] | `run: {test-command} --cov --cov-report=json`，输出 coverage-pct（从 coverage.json 解析） |
| `pr/test-java` | [自实现] | `run: mvn test` 或 `./gradlew test`，输出 surefire XML |
| `pr/check-coverage` | [外部] | `codecov/codecov-action@v5`，原生阈值检查 + PR comment。公开仓库免费。保留 bash fallback 供私有仓库使用（通过 `mode` input 切换：`codecov` | `bash`）。输出 passed（bool） |
| `pr/test-report` | [外部] | `dorny/test-reporter@v1`，支持 JUnit/Jest/pytest XML，渲染为 PR check |
| `pr/scan-deps` | [外部] | `aquasecurity/trivy-action@master`，`--scanners vuln,secret,misconfig`，扫描依赖漏洞 + secret + Dockerfile/IaC 配置错误。免费开源 |
| `pr/scan-secrets` | [外部] | `trufflesecurity/trufflehog@v3`，深度 secret 扫描（支持 git history、binary、base64 等 700+ detector）。替代 gitleaks（误报率更低） |
| `pr/scan-code` | [外部] | `github/codeql-action@v3`（init → autobuild → analyze），代码语义安全扫描。与 trivy（扫依赖）互补：CodeQL 扫代码控制流/数据流漏洞。默认语言 auto-detect，可配置 `queries: security-extended`。outputs: `results-count` |
| `pr/pr-title-check` | [外部] | `amannn/action-semantic-pull-request@v5`，Conventional Commits 格式，PR 标题必须符合规范（squash merge 后即 commit message） |
| `pr/scorecard` | [外部] | `ossf/scorecard-action@v2`，OpenSSF Scorecard 供应链安全评分。检测：branch protection、code review、CI test、vulnerabilities、pinned dependencies 等。结果上传 GitHub Security Dashboard |
| `pr/size-label` | [外部] | `pascalgn/size-label-action@v0.5.4`，按改动行数打 XS/S/M/L/XL |
| `pr/build-node` | [自实现] | `run: pnpm tsc -p tsconfig.build.json` |
| `pr/build-java` | [自实现] | `run: mvn package -DskipTests` 或 `./gradlew build -x test` |
| `pr/agent-review` | [AI] | → claude-harness，prompt: prompts/pr/code-review.md，allowed-tools: mcp__github，post-comment: true，model: sonnet |

---

### 5.5 stg 层原子

| Action | 实现方式 | 核心实现 |
|---|---|---|
| `stg/deploy` | [自实现] | inputs.deploy-command 参数化，支持 docker run / kubectl apply / fly deploy / render hook |
| `stg/health-check` | [外部] | `wait-on/wait-on-action@v1`，支持 HTTP/TCP/Unix socket，可配置超时和间隔。保留 bash fallback 通过 `mode` input 切换（`wait-on` | `bash`） |
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
| `prd/pre-check` | [自实现] | STG→PRD 发布前验证：版本对齐 + smoke test 结果 + 观察窗口 + canary watch 状态。通过 GitHub Deployments API + Checks API 查询。outputs: `pre-check-passed`、`stg-version`、`stg-deployed-at`、`observation-hours` |

**prd/pre-check 详细规格**：

inputs：

| 参数 | 类型 | 必填 | 默认值 | 说明 |
|------|------|------|--------|------|
| expected-version | string | yes | — | 当前要发布的版本 tag |
| stg-environment | string | no | 'staging' | STG environment 名称 |
| min-observation-hours | number | no | 24 | 最小观察窗口（小时） |
| force-skip-observation | boolean | no | false | 跳过观察窗口（紧急发布） |

outputs：

| 参数 | 类型 | 说明 |
|------|------|------|
| pre-check-passed | boolean | 全部检查通过 |
| stg-version | string | STG 实际部署版本 |
| stg-deployed-at | string | STG 部署时间 ISO8601 |
| observation-hours | number | 实际观察时长 |

实现：[自实现]，通过 GitHub Deployments API 查询 STG environment 最近的 deployment，验证版本、smoke test 结论、部署时间。Canary watch 状态通过查询 `prd-canary-watch.yml` workflow run 获取。

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
4. `action-manifest.yml`（初始版本，随后续批次逐步完善）
5. `scripts/validate-manifest.py`
6. `scripts/generate-action-docs.py`

**第二批（依赖 prompts，再创建）**：

7. `actions/_common/` 所有 action（setup-node/python/java, post-comment, notify, upload-coverage, **detect-language**, **annotate**, **harden-runner**, **paths-filter**, **opencommit**）
8. `actions/_common/post-comment/post-comment.js`（基于 actions/github-script@v7 的 sticky 评论逻辑）

**第三批（依赖 _common）**：

9. `actions/issue/` 所有原子（validate, classify-label, route, duplicate-check, agent-analyze, parse-command, execute-command）
10. `actions/pr/` 所有原子（**mega-lint**, typecheck-*, test-*, check-coverage, test-report, scan-deps, scan-secrets, scan-code, **scorecard**, pr-title-check, size-label, agent-review）
11. `actions/stg/` 所有原子
12. `actions/prd/` 所有原子（含新增 **pre-check**）

**第四批（依赖所有 action）**：

13. `.github/workflows/claude-harness.yml`（最核心的主工作流）
14. `.github/workflows/issue.yml`
15. `.github/workflows/issue-comment.yml`
16. `.github/workflows/stale.yml`
17. `.github/workflows/pr.yml`（统一 PR 工作流，自动检测语言）
18. `.github/workflows/ci.yml`（merge-to-main 后构建镜像 + 测试 + 签名，自动触发 stg.yml）
19. `.github/workflows/stg.yml`（由 ci.yml 调用，自动触发 prd.yml）
20. `.github/workflows/prd.yml`（由 stg.yml 调用，含 approval-gate）
21. `.github/workflows/prd-canary-watch.yml`（生产定时巡检）

**第五批（文档生成 + 校验）**：

22. 运行 `scripts/generate-action-docs.py` 生成 `docs/ACTIONS.md`
23. 运行 `scripts/validate-manifest.py` 验证 manifest 与 action.yml 一致性

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

11. **语言检测单一来源**：所有 workflow 和 composite action 必须通过 `_common/detect-language` 获取语言信息，禁止在 workflow 层内联检测逻辑。

12. **STG→PRD 发布门控**：`prd.yml` 的 pre-check 必须验证版本对齐、smoke test 结果、观察窗口三项，仅检查 deployment status 不满足要求。

13. **Action Manifest 一致性**：每次新增或修改 action 的 inputs/outputs 时，必须同步更新 `action-manifest.yml`。CI 中 `validate-manifest.py` 失败即为硬门控。

14. **可观测性 annotation**：deploy 和 release 的关键节点必须调用 `_common/annotate`，trace-id 跨 workflow 传递。

15. **单一镜像管线**：ci.yml 构建的 GHCR image 通过 `sha256` digest 传递给 stg.yml 和 prd.yml，禁止使用 mutable tag，确保所有环境部署完全相同的镜像。

16. **ci→stg→prd 链式调用**：ci.yml 通过 `workflow_call` 触发 stg.yml，stg.yml 通过 `workflow_call` 触发 prd.yml。approval-gate 通过 GitHub Environment Protection Rules 实现，不中断 workflow_call 链。

17. **Migration 安全**：ci.yml 必须运行 migration dry-run 验证 SQL 语法和约束；stg/prd 的 migrate job 在 deploy 之前执行，失败则中止部署。

18. **Runner 安全加固**：每个 workflow 的第一个 step 必须调用 `_common/harden-runner`（`step-security/harden-runner@v2`），阻止未授权网络访问和命令执行。

19. **统一 Lint 入口**：所有语言的 lint 通过 `pr/mega-lint`（`oxsecurity/metalinter@v8`）执行，禁止为单一语言创建独立 lint action。

20. **路径条件执行**：使用 `_common/paths-filter`（`dorny/paths-filter@v3`）检测变更路径，后续 job 按需执行。替代已被攻击的 `tj-actions/changed-files`。

21. **Secret 扫描**：使用 `trufflesecurity/trufflehog@v3` 替代 gitleaks，支持 git history 深度扫描和 700+ detector。

22. **供应链安全**：公开仓库必须运行 `ossf/scorecard-action@v2`，结果上传 GitHub Security Dashboard。
