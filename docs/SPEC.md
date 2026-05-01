# OpenCI 共享工作流库 — 设计规格文档

**版本**：v1.5
**用途**：可直接交给 Claude Code 实施的完整设计规格
**仓库定位**：公开 GitHub 仓库，供自己多个项目及外部项目通过 `uses:` 引用

---

## 变更日志

| 版本 | 变更内容 |
| --- | --- |
| v1.5 | 可观测性架构重构：拆分 push(deployment marker)与 pull(health report)模式；新增 actions/observability/ 目录（collect-synthesize-publish 三阶段）；新增 health-report.yml 工作流；新增十七章(GitHub 原生模板与仓库约定:PR_TEMPLATE/CODEOWNERS/labeler/auto-assign/dependabot/security.txt)；integrations/ 扩展 datadog-event/langsmith-tag/axiom-event/notify-deploy |
| v1.4 | Aicert 对比分析：新增十六章（29 项差距）；可观测性双目标设计：actions/integrations/(部署后推送 5 原子+notify-deploy composite) + actions/observability/(定时采集 5 原子+collect-all+publish-report+health-report workflow)；section 十七(GitHub 原生模板与仓库约定) |
| v1.3 | Action Marketplace 升级审计：补全 manifest.yml 缺失 action；新增 dependency-review-action、trivy-action、semantic-pull-request、paths-filter；linter 升级为 MegaLinter 多语言统一方案；淘汰 semgrep-action/vercel-action；新增六(Issue 管理体系)、七(外部服务集成:Sentry/SonarCloud/PostHog/Slack/Snyk/Linear)、十一(MegaLinter)、十二(容器安全扫描)章节；pr.yml 扩展 SonarCloud + PR 描述校验；prd.yml 扩展 Sentry release + PostHog 事件 + check-error-rate |
| v1.2 | 合并 v1.0 简洁哲学与 v1.1 实施细节；原则部分回归 prose-first 表达；保留全部 v1.1 实施规格、manifest、pre-check、附录 |
| v1.1 | 新增 Action Manifest 注册表；语言检测单一来源；市场服务深度集成（Codecov / CodeQL / harden-runner）；STG→PRD 强化 pre-check（版本对齐 + 观察窗口）；可观测性 annotation 规范 |
| v1.0 | 初始版本：三层架构 + 四条设计原则 |

---

## 一、项目概述与设计原则

### 1.1 项目定位

本仓库是一个 GitHub Actions 共享库,提供三层可复用单元:

- **主工作流（Reusable Workflow）**：完整的阶段流水线，调用方一行引入  
  `uses: org/opencl/.github/workflows/pr.yml@v2`
- **Composite Action**：阶段内的组合逻辑，封装多个原子  
  `uses: org/opencl/actions/pr/lint-code@v2`
- **原子 Action**：最小职责单元，单一功能，明确输入输出  
  `uses: org/opencl/actions/pr/lint-node@v2`

所有涉及 AI 的步骤统一通过 `claude-harness.yml` 执行,不直接在各 action 中调用 Claude API。

### 1.2 五条设计原则

#### 原则一：变化频率决定位置

Prompt 独立于 Action 存放,因为两者变化频率不同。Action 结构数月不变,Prompt 每周调优。Scripts 跟随调用它的 Action,不集中存放,除非被两个以上 Action 复用才提到 `lib/`。第三方依赖的 SHA 集中维护在 `manifest.yml`,因为它需要全仓库统一更新。

具体落点:

- Prompt → `prompts/{stage}/{task}.md`
- Action 实现 → `actions/{stage}/{name}/`
- 工作流主干 → `.github/workflows/`
- 复用脚本 → 跟随 action,2+ 共用才提到 `lib/`
- 第三方 SHA → `manifest.yml` 的 `deps` 节点（**唯一来源**）

#### 原则二：命名即语义

Action 命名格式:`动词-名词`（`lint-node`、`scan-deps`、`tag-release`）。目录命名格式:名词（`issue`、`pr`、`stg`、`prd`）。Composite 与原子同在阶段目录下,通过名称复杂度区分粒度,不单独建 `composites/` 目录。

固定动词词汇表,保证全仓库语义一致:

| 动词 | 语义 | 例 |
| --- | --- | --- |
| `detect-` | 探测识别 | `detect-language` |
| `lint-` | 静态检查 | `lint-node`, `lint-python` |
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

#### 原则三：调用层级单向

主工作流调用 Composite,Composite 调用原子,原子不互相调用。AI 原子统一向上调用 `claude-harness.yml`,不直接调用 Claude API。

```
主工作流（Reusable Workflow）
  └── Composite Action（阶段级）
        └── 原子 Action（单一功能）
              └── （AI 原子专属）→ claude-harness.yml
```

具体约束:

- 原子之间不互相调用
- Composite 不调用其他 Composite
- 主工作流不直接调用原子（必须经过 Composite）
- `claude-harness.yml` 是唯一可被原子向上调用的主工作流

#### 原则四：外部优于自实现

有成熟的 Verified Creator action 时,优先封装使用,不重复造轮子。自实现仅用于:无现成方案、命令因项目而异（build/test/deploy）、业务规则特定（slash command、smoke-test）。

决策规则:

```
存在 GitHub Verified Creator action？
  ├── 是 → 封装使用,输入输出适配,不修改其行为
  └── 否 → 以下情况才自实现:
       ├── 命令因项目而异（build / test / deploy 命令）
       ├── 业务规则特定（slash command 解析、smoke test 路径）
       └── 无现成方案覆盖（如 prompt 推送到 Langfuse）
```

反模式:不得自实现 Docker 构建、secret 扫描、覆盖率上报等已有成熟方案的功能。

#### 原则五：安全默认（v1.1 新增）

供应链攻击是 GitHub Actions 生态的实质性威胁（tj-actions 2025/03、trivy-action 2026/03 相继被攻击）。设计上必须假定每个第三方 action 都可能被劫持。因此:

- **SHA 固定**:所有第三方 action 必须使用 commit SHA,不接受版本 tag
- **SHA 集中**:所有 SHA 维护在 `manifest.yml`,不在 action 内硬编码
- **权限最小化**:每个 job 显式声明 `permissions`,仅开放必要权限
- **harden-runner 必装**:每个工作流每个 job 第一步统一加载,审计出站连接
- **OIDC 优先**:认证使用 OIDC（id-token）,避免长期凭证

---

## 二、目录结构

```
opencl/
├── .github/
│   ├── ISSUE_TEMPLATE/                    # Issue 模板范例(消费方可复制使用)
│   │   ├── bug-report.yml
│   │   ├── feature-request.yml
│   │   ├── question.yml
│   │   ├── security-report.yml            # 安全漏洞走私下渠道
│   │   └── config.yml                     # 禁止空白 issue + 外链
│   │
│   ├── PULL_REQUEST_TEMPLATE.md           # PR 描述模板(v1.5 新增)
│   ├── CODEOWNERS                         # 代码所有权,自动指定 reviewer(v1.5 新增)
│   ├── dependabot.yml                     # 依赖自动更新(v1.5 新增)
│   ├── labeler.yml                        # 按文件路径自动打 label(v1.5 新增)
│   ├── auto-assign.yml                    # PR 自动指定 reviewer(v1.5 新增)
│   │
│   └── workflows/                         # 主工作流(供外部 uses: 引用)
│       ├── claude-harness.yml             # AI 引擎(唯一 Claude 入口)
│       ├── issue.yml                      # Issue 生命周期管理
│       ├── issue-comment.yml              # Issue 评论处理(slash command)
│       ├── pr.yml                         # PR 质量门
│       ├── ci.yml                         # Merge to main 构建与冒烟
│       ├── stg.yml                        # Staging 部署
│       ├── prd.yml                        # 生产发布(含强化 pre-check)
│       ├── security-schedule.yml          # 定时全量安全扫描
│       ├── docs-build.yml                 # PR 时文档构建验证
│       ├── docs-deploy.yml                # main push 文档部署
│       ├── release-docker.yml             # Docker 镜像发布与签名
│       ├── stale.yml                      # 过期 Issue/PR 自动标记
│       ├── community.yml                  # 新贡献者欢迎 + 冲突检测
│       └── health-report.yml              # 定时健康日报(collect→synthesize→publish)(v1.5 新增)
│
├── actions/
│   ├── _common/                           # 跨阶段复用
│   │   ├── detect-language/              # 语言检测(v1.1 单一来源)
│   │   ├── setup-env/                    # 环境准备
│   │   ├── post-comment/                 # GitHub 评论发布
│   │   └── read-manifest/               # 读取 manifest.yml 的 deps
│   │
│   ├── issue/                             # Issue 阶段(v1.3 扩展)
│   │   ├── auto-label/                    # 基于 form 字段自动打 label
│   │   ├── ai-triage/                     # AI 分级(priority + 路由)
│   │   ├── detect-duplicates/             # 相似 issue 检测
│   │   ├── welcome-contributor/           # 新贡献者欢迎
│   │   ├── auto-assign/                   # CODEOWNERS 自动分配
│   │   ├── parse-command/                 # slash 命令解析
│   │   ├── execute-command/               # slash 命令执行
│   │   └── validate-form/                 # 必填字段校验
│   │
│   ├── pr/
│   │   ├── lint-code/                     # Composite: MegaLinter 多语言统一 lint
│   │   ├── test-unit/                     # Composite: 运行单元测试
│   │   ├── scan-deps/                     # 原子: dependency-review
│   │   ├── scan-secrets/                  # 原子: TruffleHog
│   │   ├── scan-sonarcloud/               # 原子: SonarCloud 代码质量(v1.3)
│   │   ├── check-coverage/                # 原子: Codecov 集成
│   │   ├── validate-pr-description/       # 原子: PR 描述校验(v1.3)
│   │   ├── review-ai/                     # 原子: AI PR review
│   │   └── eval-prompt/                   # 原子: promptfoo 回归
│   │
│   ├── ci/
│   │   ├── build-docker/                  # 原子: 构建并推送 GHCR
│   │   ├── scan-image/                    # 原子: Trivy 镜像扫
│   │   ├── sign-image/                    # 原子: Cosign 签名
│   │   ├── eval-smoke/                    # 原子: AI 冒烟 eval
│   │   └── check-migration/              # 原子: DB migration dry-run
│   │
│   ├── stg/
│   │   ├── deploy-k8s/                    # 原子: kubectl 滚动部署
│   │   ├── run-migration/                 # 原子: 执行 migration
│   │   ├── smoke-test/                    # 原子: HTTP 健康检查
│   │   └── notify-deployed/               # 原子: Slack 通知
│   │
│   ├── prd/
│   │   ├── pre-check/                     # Composite: 双验证(v1.1)
│   │   ├── verify-version-align/          # 原子: STG/PRD digest 对齐
│   │   ├── observe-window/                # 原子: 观察窗口等待
│   │   ├── check-error-rate/              # 原子: Sentry 错误率检查(v1.3)
│   │   ├── deploy-k8s/                    # 原子: 生产部署
│   │   ├── run-migration/                 # 原子: 生产 migration
│   │   ├── smoke-test/                    # 原子: 生产冒烟
│   │   └── create-release/               # 原子: GitHub Release
│   │
│   ├── security/
│   │   ├── scan-codeql/                   # 原子: CodeQL SAST
│   │   ├── scan-image-full/               # 原子: Trivy 全量
│   │   └── generate-sbom/                # 原子: SBOM 生成
│   │
│   ├── community/                         # 社区互动(v1.3 新增)
│   │   ├── stale-mark/
│   │   ├── stale-close/
│   │   └── lock-resolved/
│   │
│   ├── integrations/                      # 外部 SaaS 集成(v1.3 新增,v1.5 扩展)
│   │   ├── sentry-release/                # Sentry 发布通知(getsentry/action-release)
│   │   ├── datadog-event/                 # Datadog 部署事件(curl POST /api/v1/events)
│   │   ├── posthog-event/                 # PostHog 事件上报(curl POST /capture/)
│   │   ├── langsmith-tag/                 # LangSmith deployment 元数据标签(curl POST runs)
│   │   ├── axiom-event/                   # Axiom deployment log(curl POST /v1/datasets/ingest)
│   │   ├── slack-notify/                  # Slack 通知
│   │   ├── linear-link/                   # Linear issue 关联检查
│   │   └── notify-deploy/                 # Composite:按 input flag 扇出到上面 5 个原子(v1.5)
│   │
│   └── observability/                     # 可观测性数据采集(v1.5 新增)
│       ├── query-sentry/                  # 原子:拉 Sentry 数据 → JSON
│       ├── query-datadog/                 # 原子:拉 Datadog 数据 → JSON
│       ├── query-posthog/                 # 原子:拉 PostHog 数据 → JSON
│       ├── query-langsmith/               # 原子:拉 LangSmith 数据 → JSON
│       ├── query-axiom/                   # 原子:拉 Axiom 数据 → JSON
│       ├── collect-all/                   # Composite:串行调用全部 query-*
│       ├── post-issue-report/             # 原子:报告发成 GitHub Issue
│       ├── post-slack-report/             # 原子:报告发到 Slack
│       └── publish-report/                # Composite:同时 post issue + slack
│
├── prompts/                               # AI Prompt(与 action 分离)
│   ├── pr/
│   │   ├── review.md
│   │   └── eval-regression.md
│   ├── issue/
│   │   └── triage.md
│   ├── ci/
│   │   └── smoke-eval.md
│   └── observability/                     # v1.5 新增
│       └── daily-health-report.md         # 健康日报合成指令
│
├── lib/                                   # 2+ action 共用脚本
│   ├── wait-on.js                         # 观察窗口实现
│   └── parse-sarif.sh                     # SARIF 解析
│
├── manifest.yml                           # Action Manifest 注册表
├── README.md
├── LICENSE                                # Apache 2.0 推荐(对专利友好)
├── CHANGELOG.md                           # 版本历史(release-drafter 自动生成)
├── CONTRIBUTING.md                        # 贡献指南:fork → branch → PR 流程
├── CODE_OF_CONDUCT.md                     # 行为准则(Contributor Covenant)
├── SECURITY.md                            # 漏洞报告渠道
├── .gitignore
└── .well-known/
    └── security.txt                       # 安全研究人员标准文件(v1.5 新增)
```

---

## 三、Action Manifest 注册表

`manifest.yml` 是全仓库的单一来源索引。所有 action 文件从此读取第三方 SHA,不得在 action 内硬编码。

```yaml
# manifest.yml
version: "1.3"

# ─────────────────────────────────────────────────────────────────────────────
# 第三方依赖 SHA 注册表
# 更新方式:Renovate Bot 自动提 PR,或手动 PR + code review
# ⚠️ 安全要求:
#   - 所有第三方 action 必须使用 commit SHA,不接受版本 tag
#   - trivy-action 的 tag 于 2026-03 被供应链攻击篡改,必须固定 SHA
#   - trufflehog 不得使用 @main,必须固定到发布版本 SHA
#   - semgrep-action 已废弃(2020 年停更),改用 CLI 直接调用
#   - amondnet/vercel-action 版本滞后严重,改用官方 Vercel CLI
# ─────────────────────────────────────────────────────────────────────────────
deps:
  # ── GitHub 官方 ─────────────────────────────────────────────────────────
  actions/checkout:                    "11bd71901bbe5b1630ceea73d27597364c9af683"  # v4.2.2
  actions/setup-node:                  "49933ea5288caeca8642d1e84afbd3f7"          # v4.4.0
  actions/setup-python:                "a26af69be951a213d495a4c3e4e4022e16d87065"  # v5.6.0
  actions/setup-go:                    "d35c59abb061a4a6fb18e82ac0862c26744d6ab5"  # v5.5.0
  actions/cache:                       "5a3ec84eff668545956fd18f4cc68c71c9f62eb4"  # v4.2.2
  actions/upload-artifact:             "ea165f8d65b6e75b540449e92b4886f43607fa02"  # v4.6.2
  actions/download-artifact:           "d3f86a106a0bac45b974a628896c90dbdf5c8093"  # v4.3.0
  actions/dependency-review-action:    "38e6c9cc40b09fb67ca04a29eb89ad60c93adb9b"  # v4.6.0
  actions/github-script:               "60a0d83039c74a4aee543508d2ffcb1c3799cdea"  # v7.0.1

  # ── Docker ──────────────────────────────────────────────────────────────
  docker/setup-buildx-action:          "b5ca514318bd6ebac0fb2aedd5d36ec1b5c232a2"  # v3.10.0
  docker/login-action:                 "74a5d142397b4f367a81961eba4e8cd7edddf772"  # v3.4.0
  docker/metadata-action:              "902fa8ec7d6ecbf8d84d538b9b233a880e428804"  # v5.7.0
  docker/build-push-action:            "263435318d21b8e681c14492fe198e19c3bc6bb6"  # v6.18.0

  # ── AWS ─────────────────────────────────────────────────────────────────
  aws-actions/configure-aws-credentials: "e3dd6a429d7300a6a4c196c26e071d42e0343502"  # v4.2.1
  aws-actions/amazon-ecs-deploy-task-definition: "df00883c1e5554e48a7b1e9e8d34e1b0a2e1b3b1"  # v2.2.0

  # ── 包管理 ──────────────────────────────────────────────────────────────
  pnpm/action-setup:                   "a7487c7e89a18df4991f7f222e4b3e4f"          # v4.0.0
  astral-sh/setup-uv:                  "v5"  # ⚠️ 待 SHA 固定,Renovate 自动处理

  # ── 安全 ────────────────────────────────────────────────────────────────
  step-security/harden-runner:         "f808768d1510423e83855289c910610ca9b43176"  # v2.17.0
  trufflesecurity/trufflehog:          "fbc87d9d42c8f498b51d2d7e37c2b7c6c3b1a9b"  # v3.88.0
  aquasecurity/trivy-action:           "18f2963bb4bb342b8b1fc1f4d9f682a8e12d0e9"  # 手动验证 SHA
  sigstore/cosign-installer:           "59acb6260d9c0ba8f4a2f9d9b48431a222b68e20"  # v3.5.0
  github/codeql-action:                "23dab4bc6e7e24150d9e35e3b3260f29ea78e5c0"  # v3.28.0
  ossf/scorecard-action:               "f49aabe0b5af0936a0987cfb85d86b75b087d84f"  # v2.4.0

  # ── PR 质量 ─────────────────────────────────────────────────────────────
  amannn/action-semantic-pull-request: "0075b94f90e932db85bd6f29cd6b34cf5a97c06"   # v5.5.3
  dorny/paths-filter:                  "de90cc6fb38fc0963ad72b210f1f284cd68cea1e"  # v3.0.2
  dorny/test-reporter:                 "31a54ee7ebcacc03a09ea97a7e5465a47b84efa5"  # v1.9.0
  peter-evans/create-or-update-comment: "71e7c2b9743baf70b8db35407c8c2b11fb1b09cd" # v3.0.0
  codecov/codecov-action:              "1e68e06f1dbfde0e4cefc87efeba9e4bb7dd5ced"  # v5.4.0

  # ── AI / Eval ───────────────────────────────────────────────────────────
  anthropics/claude-code-action:       "a4d5fe83c90d37e4f2fcbab2a0bf04e9c01e8ecf"  # v1.0.0
  promptfoo/promptfoo-action:          "8e12b04e93d24ea43d7694d8f27dd86e7abd5a72"  # v1.0.0

  # ── 发布 ────────────────────────────────────────────────────────────────
  release-drafter/release-drafter:     "3f0f87098bd6b5c5b9a36d49c41d998ea58f9e0b"  # v6.1.0

  # ── 部署（第三方） ──────────────────────────────────────────────────────
  appleboy/ssh-action:                 "v1.2.5"  # ⚠️ 待 SHA 固定

# ─────────────────────────────────────────────────────────────────────────────
# 已淘汰 action（禁止使用,保留记录供迁移参考）
# ─────────────────────────────────────────────────────────────────────────────
deprecated:
  semgrep/semgrep-action:
    reason: "2020 年停更,不再维护。改用 CLI: pip install semgrep && semgrep ci"
    replacement: "直接调用 semgrep CLI,通过 setup-python 安装"
  amondnet/vercel-action:
    reason: "版本严重滞后(v25 vs 最新 v42.3.0),功能不全"
    replacement: "官方 Vercel CLI: npm i -g vercel && vercel deploy --prod"

# ─────────────────────────────────────────────────────────────────────────────
# 主工作流目录（供消费方 uses: 引用）
# ─────────────────────────────────────────────────────────────────────────────
workflows:
  - id: claude-harness
    path: .github/workflows/claude-harness.yml
    description: AI 执行引擎,所有 Claude 调用的唯一入口
    inputs:
      task: { type: string, required: true }
      prompt-path: { type: string, required: false, description: "调用方自定义 prompt 路径,空则用内置" }
      context: { type: string, required: false, description: "JSON 格式 prompt 变量" }
      model: { type: string, default: "claude-sonnet-4-5-20250929" }
      max-turns: { type: number, default: 10 }
    outputs:
      result: "AI 输出内容"
      comment-id: "PR/Issue 评论 ID（sticky 模式用于后续更新）"
    secrets:
      anthropic-api-key: { required: true }

  - id: pr
    path: .github/workflows/pr.yml
    description: PR 质量门
    inputs:
      language: { type: string, default: "" }
      enable-ai-review: { type: boolean, default: true }
      enable-eval: { type: boolean, default: false }
      coverage-threshold: { type: number, default: 80 }
      pr-review-prompt-path: { type: string, default: "" }
    secrets:
      anthropic-api-key: { required: false }
      codecov-token: { required: false }

  - id: ci
    path: .github/workflows/ci.yml
    description: Merge to main 构建与冒烟
    inputs:
      language: { type: string, default: "" }
      registry: { type: string, default: "ghcr.io" }
      image-name: { type: string, required: true }
      enable-ai-smoke: { type: boolean, default: false }
      run-migration: { type: boolean, default: false }
    outputs:
      image-digest: "sha256:xxx 格式"
      deploy-time: "ISO 8601 构建完成时间"
    secrets:
      registry-token: { required: true }
      anthropic-api-key: { required: false }

  - id: stg
    path: .github/workflows/stg.yml
    description: Staging 部署
    inputs:
      image-digest: { type: string, required: true }
      k8s-namespace: { type: string, default: "staging" }
      run-migration: { type: boolean, default: false }
    outputs:
      deploy-time: "ISO 8601,传给 prd 的 stg-deploy-time"
    secrets:
      kubeconfig-stg: { required: true }

  - id: prd
    path: .github/workflows/prd.yml
    description: 生产发布（含 pre-check）
    inputs:
      image-digest: { type: string, required: true }
      stg-image-digest: { type: string, required: true }
      stg-deploy-time: { type: string, required: true }
      observation-minutes: { type: number, default: 30 }
      k8s-namespace: { type: string, default: "production" }
    secrets:
      kubeconfig-prd: { required: true }

  - id: security-schedule
    path: .github/workflows/security-schedule.yml
    description: 每周全量安全扫描
    inputs:
      image-ref: { type: string, required: false }
```

---

## 四、语言检测单一来源

**文件**:`actions/_common/detect-language/action.yml`

**职责**:根据仓库根目录文件探测语言栈,输出标准化语言标识符。所有需要语言信息的工作流均通过此 action 获取,不允许各工作流自行实现检测逻辑。

**输入**:无（读取 `github.workspace` 文件系统）

**输出**:

```yaml
outputs:
  language:           # node | python | go | java | unknown
  package-manager:    # npm | pnpm | yarn | uv | pip | go-mod | maven | unknown
  version-file:       # .nvmrc | .python-version | go.mod | pom.xml | ""
  runtime-version:    # 从 version-file 读取的版本号
```

**检测规则**（优先级从高到低,找到即停）:

```
1. package.json 存在 → language=node
   ├── pnpm-lock.yaml    → package-manager=pnpm
   ├── yarn.lock         → package-manager=yarn
   └── package-lock.json → package-manager=npm（默认）
   version-file: .nvmrc 或 .node-version

2. pyproject.toml 或 requirements.txt 存在 → language=python
   ├── uv.lock → package-manager=uv
   └── 否则   → package-manager=pip
   version-file: .python-version

3. go.mod 存在 → language=go, package-manager=go-mod

4. pom.xml 存在 → language=java, package-manager=maven

5. 全部未匹配 → language=unknown
```

**实现**:纯 shell composite action,不引用任何外部 action,保证零依赖。

**Annotation**:
```bash
echo "::notice title=Language Detected::language=$LANGUAGE package-manager=$PKG_MGR"
```

---

## 五、主工作流规格

### 5.1 claude-harness.yml

所有 AI 调用的唯一入口,统一管理模型参数、sticky comment、prompt 加载逻辑。

**触发**:`workflow_call` only（不接受其他触发器）

**Prompt 加载优先级**:
1. 若 `prompt-path` 非空,从调用方仓库加载（支持消费方覆盖,无需 fork）
2. 若为空,从 `opencl/prompts/{task}.md` 加载内置 prompt

**实现要点**:
- 使用 `anthropics/claude-code-action` 的 `use_sticky_comment: true`,同一 PR 多次触发只更新同一条评论
- `context` 输入作为 JSON 注入 prompt 模板变量
- 调用记录到 annotation:`::notice title=AI Task::task=$TASK model=$MODEL turns=$TURNS`

**权限**:
```yaml
permissions:
  contents: read
  pull-requests: write
  issues: write
  id-token: write
```

### 5.2 pr.yml

**触发**:`workflow_call`

**Job 依赖图**:

```
┌─ harden-runner（每 job 第一步）
│
├─ detect-language [if: inputs.language == '']
│       │ outputs: language, package-manager
│       ▼
│
├─ lint              [needs: detect-language]  [阻断]
│   └── oxsecurity/megalinter（SHA 固定）
│       ├── 自动检测仓库语言栈,无需手动路由
│       ├── 支持 85+ linter / 50+ 语言格式
│       ├── 配置: .megalinter.yml（消费方可覆盖）
│       └── flavor: 基于 detect-language 选择精简镜像
│
├─ test              [needs: detect-language]  [阻断]
│   └── test-unit composite
│         ├── 运行测试（消费方提供 test 命令）
│         ├── dorny/test-reporter → GitHub Check
│         └── upload coverage artifact
│
├─ coverage          [needs: test]              [非阻断]
│   └── check-coverage → codecov-action
│
├─ scan-deps         [独立]                      [阻断]
│   └── actions/dependency-review-action(v4.6.0,SHA 固定)
├─ scan-secrets      [独立]                      [非阻断]
│   └── trufflesecurity/trufflehog(v3.88.0,SHA 固定,禁止 @main)
├─ scan-sonarcloud   [独立]                      [非阻断]
│   └── SonarSource/sonarcloud-github-action(SHA 固定)
│       └── PR decoration: quality gate + bug/vulnerability/code smell
├─ validate-pr-title [独立]                      [阻断]
│   └── amannn/action-semantic-pull-request(v5.5.3,SHA 固定)
├─ validate-pr-desc  [独立]                      [阻断]
│   └── 检查 Closes #N / Fixes #N 或 no-issue label
│
├─ build-check       [needs: detect-language]   [阻断]
│   └── docker build --load(仅验证,不推送)
│
└─ ai-review         [needs: lint, test]        [非阻断]
    └── review-ai → claude-harness（task: pr-review）
          │
          └─ eval-prompt [needs: ai-review]      [非阻断]
                         [if: enable-eval && paths.prompts changed]
              └── eval-prompt → promptfoo-action
```

**权限**:
```yaml
permissions:
  contents: read
  pull-requests: write
  security-events: write
  id-token: write
```

### 5.3 ci.yml

**Job 依赖图**:

```
detect-language
      │
      ▼
build-docker ──→ [outputs: image-digest, image-size]
      │
      ├── scan-image（aquasecurity/trivy-action,SHA 固定）→ upload SARIF
      │   详见「九、容器安全扫描」章节
      │
      ├── sign-image（Cosign OIDC 签名）
      │
      ├── check-migration [if: run-migration]
      │
      └── eval-smoke [if: enable-ai-smoke, needs: build-docker]
               └── eval-smoke → claude-harness（task: smoke-eval）
```

**Image 命名**:
```
ghcr.io/{owner}/{image-name}:main           # latest 语义
ghcr.io/{owner}/{image-name}:sha-{git-sha}  # 精确定位（7位短 SHA）
```

**Outputs 传递**:
```yaml
outputs:
  image-digest:
    value: ${{ jobs.build-docker.outputs.digest }}
  deploy-time:
    value: ${{ jobs.build-docker.outputs.completed-at }}
```

### 5.4 stg.yml

**Job 顺序**（串行,失败即停）:

```
pre-flight → deploy-k8s → run-migration → smoke-test → notify-deployed
```

**deploy-k8s 实现**:
```bash
kubectl set image deployment/{app-name} \
  app=ghcr.io/{owner}/{image}@$IMAGE_DIGEST \
  --namespace=$K8S_NAMESPACE
kubectl rollout status deployment/{app-name} \
  --namespace=$K8S_NAMESPACE \
  --timeout=300s
```

**Outputs**:
```yaml
outputs:
  deploy-time:
    value: ${{ steps.deploy.outputs.completed-at }}
```

### 5.5 prd.yml(v1.1 强化,v1.3 扩展)

**触发**:`workflow_call` + `environment: production`(触发 GitHub 审批保护规则)

**Job 顺序**:

```
pre-check(version-align + observe-window + check-error-rate)
      │ [environment: production 审批在此处触发]
      ▼
deploy-k8s → run-migration → smoke-test → create-release → notify-deployed
      │                                              │
      ├── sentry-release(staging)                    ├── sentry-release(production)
      └── posthog-event(deploy)                      └── posthog-event(release)
```

**v1.3 扩展**:

- **check-error-rate**:观察窗口内不再仅 sleep,通过 Sentry API 检查 STG 错误率,异常则阻断 PRD 部署
- **sentry-release**:每次部署后通知 Sentry 创建 release,关联 commit 范围
- **posthog-event**:上报 deploy/release 事件到 PostHog,用于后续用户行为与部署时间点关联分析

#### pre-check Composite

包含两个串行子步骤:

**步骤一:verify-version-align**

```yaml
# actions/prd/verify-version-align/action.yml
inputs:
  image-digest:     { required: true }
  stg-image-digest: { required: true }

runs:
  using: composite
  steps:
    - name: Compare digests
      shell: bash
      run: |
        if [ "${{ inputs.image-digest }}" != "${{ inputs.stg-image-digest }}" ]; then
          echo "::error title=Version Mismatch::PRD digest != STG digest"
          echo "::error::请确认 STG 与 PRD 使用相同镜像,防止"测的和上的不一致""
          exit 1
        fi
        echo "::notice title=Version Aligned::digest=${{ inputs.image-digest }} ✓"
```

**步骤二:observe-window**

```yaml
# actions/prd/observe-window/action.yml
inputs:
  stg-deploy-time:     { required: true }   # ISO 8601
  observation-minutes: { required: false, default: "30" }

runs:
  using: composite
  steps:
    - name: Wait for observation window
      shell: bash
      run: |
        STG_TIME=$(date -d "${{ inputs.stg-deploy-time }}" +%s)
        NOW=$(date +%s)
        ELAPSED=$(( (NOW - STG_TIME) / 60 ))
        REQUIRED=${{ inputs.observation-minutes }}
        
        echo "::notice title=Observation Window::elapsed=${ELAPSED}min required=${REQUIRED}min"
        
        if [ $ELAPSED -lt $REQUIRED ]; then
          WAIT=$(( (REQUIRED - ELAPSED) * 60 ))
          echo "::notice title=Waiting::STG 部署后仅 ${ELAPSED}min,等待 $(( WAIT/60 ))min"
          sleep $WAIT
        fi
        
        echo "::notice title=Observation Window OK::elapsed=${ELAPSED}min ≥ required=${REQUIRED}min ✓"
```

### 5.6 security-schedule.yml

**触发**:
```yaml
on:
  schedule:
    - cron: '0 2 * * 1'   # 每周一 UTC 02:00
  workflow_dispatch:
  workflow_call:
    inputs:
      image-ref: { type: string, required: false }
```

**Job 并行执行**:
```
codeql-scan    → upload SARIF → GitHub Security tab
scan-image     → upload SARIF [if: image-ref != '']
generate-sbom  → upload artifact
scorecard      → upload to OpenSSF
```

---

## 六、Issue 管理体系(v1.3 新增)

Issue 是产品反馈、bug 报告、功能讨论的入口。一个成熟项目的 issue 管理需要:模板规范 + 自动分类 + 生命周期管理 + 与 PR 的双向联动。

### 6.1 Issue Templates(YAML Form)

GitHub 现代化的 issue form 比传统 markdown 模板有结构化优势——必填字段、下拉选项,直接产出可机读数据,后续 AI triage 和 auto-label 都依赖这个结构。

OpenCI 在 `.github/ISSUE_TEMPLATE/` 提供模板范例,消费方可直接复制使用。

**bug-report.yml 范例**:

```yaml
name: Bug Report
description: 报告一个 bug
labels: ["type:bug", "status:needs-triage"]
body:
  - type: input
    id: version
    attributes:
      label: 版本
      placeholder: "v1.2.3 或 commit SHA"
    validations:
      required: true

  - type: dropdown
    id: area
    attributes:
      label: 影响领域
      options: [frontend, backend, infra, db, ai, docs]
    validations:
      required: true

  - type: textarea
    id: reproduction
    attributes:
      label: 复现步骤
      description: 详细步骤,从 1 开始编号
    validations:
      required: true

  - type: textarea
    id: expected
    attributes:
      label: 期望行为
    validations:
      required: true

  - type: dropdown
    id: severity
    attributes:
      label: 严重程度
      options:
        - 阻塞(无法使用)
        - 严重(主要功能受影响)
        - 一般(部分功能受影响)
        - 轻微(影响有限)
    validations:
      required: true
```

`feature-request.yml` 和 `question.yml` 同样是 YAML form 结构。

### 6.2 issue.yml 工作流

**触发**: `issues: types: [opened]`

**Job 依赖图**:

```
validate-form (检查必填字段是否填写)
    │ pass
    ▼
auto-label (基于 form 字段打 area:* / severity:*)
    │
    ├── detect-duplicates (用 GitHub Search API 找相似)
    │     │ found
    │     └── 评论提示 + 打 possible-duplicate label
    │
    ├── ai-triage (调用 claude-harness)
    │     │
    │     ▼ AI 输出 priority + reasoning
    │     打 priority:* label
    │
    ├── welcome-contributor [if: FIRST_TIME_CONTRIBUTOR]
    │     └── 评论欢迎 + 贡献指南
    │
    └── auto-assign (基于 CODEOWNERS + area label)
          └── 设置 assignee
```

**关键原子规格**:

`actions/issue/ai-triage/action.yml`:

```yaml
inputs:
  issue-number:    { required: true }
  issue-title:     { required: true }
  issue-body:      { required: true }
  prompt-path:     { required: false, default: "" }

runs:
  using: composite
  steps:
    - uses: ./actions/_common/claude-harness    # 经由 harness
      with:
        task: issue-triage
        prompt-path: ${{ inputs.prompt-path }}
        context: |
          {
            "title": "${{ inputs.issue-title }}",
            "body": "${{ inputs.issue-body }}",
            "number": ${{ inputs.issue-number }}
          }
        # 内置 prompt 要求 AI 输出 JSON:
        # {
        #   "priority": "p0|p1|p2|p3",
        #   "reasoning": "...",
        #   "suggested_assignee": "@user 或 null",
        #   "is_security": boolean
        # }

    - name: Apply labels
      shell: bash
      run: |
        PRIORITY=$(echo '${{ steps.harness.outputs.result }}' | jq -r '.priority')
        IS_SECURITY=$(echo '${{ steps.harness.outputs.result }}' | jq -r '.is_security')

        gh issue edit ${{ inputs.issue-number }} \
          --add-label "priority:$PRIORITY"

        if [ "$IS_SECURITY" = "true" ]; then
          gh issue edit ${{ inputs.issue-number }} \
            --add-label "security" \
            --add-label "private-discuss"
        fi

        echo "::notice title=AI Triage::priority=$PRIORITY security=$IS_SECURITY"
```

`actions/issue/detect-duplicates/action.yml`:

```yaml
inputs:
  issue-number:  { required: true }
  issue-title:   { required: true }

runs:
  using: composite
  steps:
    - name: Search similar issues
      shell: bash
      run: |
        KEYWORDS=$(echo "${{ inputs.issue-title }}" | tr ' ' '\n' | \
                   grep -v -i -E "^(the|a|an|is|are|of|in|on|to)$" | head -5 | tr '\n' ' ')

        SIMILAR=$(gh issue list \
          --search "$KEYWORDS in:title is:open -number:${{ inputs.issue-number }}" \
          --json number,title \
          --limit 5)

        COUNT=$(echo "$SIMILAR" | jq 'length')

        if [ "$COUNT" -gt 0 ]; then
          MSG="检测到 $COUNT 个可能相关的 issue:\n"
          MSG+=$(echo "$SIMILAR" | jq -r '.[] | "- #\(.number) \(.title)"')
          MSG+="\n\n如果是重复 issue,请评论 \`/duplicate #N\`,否则请忽略此提示。"

          gh issue comment ${{ inputs.issue-number }} --body "$MSG"
          gh issue edit ${{ inputs.issue-number }} --add-label "possible-duplicate"

          echo "::notice title=Possible Duplicates::count=$COUNT"
        fi
```

### 6.3 issue-comment.yml(slash 命令)

**触发**: `issue_comment: types: [created]`

**支持的命令**:

| 命令 | 权限 | 行为 |
| --- | --- | --- |
| `/assign @user` | OWNER/MEMBER/COLLABORATOR | 设置 assignee |
| `/unassign` | 同上 | 清除 assignee |
| `/label name` | 同上 | 添加 label |
| `/unlabel name` | 同上 | 移除 label |
| `/priority p1` | 同上 | 设置 priority(快捷加 label) |
| `/close` | 同上 | 关闭 issue |
| `/reopen` | 同上 | 重开 issue |
| `/duplicate #123` | 同上 | 标记重复并关闭 |
| `/needs-info` | 同上 | 添加 needs-info + 引导评论 |
| `/triage` | 同上 | 重跑 AI triage |
| `/help` | 任何人 | 列出所有命令 |

**实现要点**:

权限通过 `github.event.comment.author_association` 字段判断,值为 `OWNER` / `MEMBER` / `COLLABORATOR` / `CONTRIBUTOR` / `FIRST_TIME_CONTRIBUTOR` / `NONE`。前三类为高权限。

```yaml
# actions/issue/parse-command/action.yml
outputs:
  command:    # 提取的命令名
  args:       # 命令参数
  authorized: # bool

# actions/issue/execute-command/action.yml
# 根据 command 分支:
#   /assign  → gh issue edit --add-assignee
#   /label   → gh issue edit --add-label
#   /close   → gh issue close
#   ...
```

### 6.4 community.yml(社区互动)

**触发**: `pull_request: [opened]` + `issues: [opened]` + `issue_comment: [created]`

**职责**(跨 issue/PR 的事件统一处理):

- **新贡献者欢迎**:第一次提 PR 或 issue 的用户,评论欢迎 + 贡献指南链接
- **CLA 检查**(若适用):验证签署了 CLA,未签则 block
- **PR ↔ Issue 联动验证**:PR 描述里 `Closes #N` / `Fixes #N` 的语法检查
- **冲突检测**:PR 与 main 出现 merge conflict 时,自动评论提醒作者 rebase

### 6.5 stale.yml(过期清理)

**触发**: `schedule: cron: '0 2 * * *'`(每天 UTC 02:00)

```yaml
on:
  workflow_call:
    inputs:
      issue-stale-days:   { default: 60 }
      issue-close-days:   { default: 14 }
      pr-stale-days:      { default: 30 }
      pr-close-days:      { default: 7 }

jobs:
  stale:
    steps:
      - uses: actions/stale@{SHA}
        with:
          days-before-issue-stale: ${{ inputs.issue-stale-days }}
          days-before-issue-close: ${{ inputs.issue-close-days }}
          days-before-pr-stale: ${{ inputs.pr-stale-days }}
          days-before-pr-close: ${{ inputs.pr-close-days }}
          stale-issue-label: 'status:stale'
          stale-issue-message: |
            此 issue 已 ${{ inputs.issue-stale-days }} 天无活动,标记为 stale。
            ${{ inputs.issue-close-days }} 天内无回应将自动关闭。
            如需保留,请评论说明或移除 stale 标签。
          exempt-issue-labels: 'pinned,security,help-wanted,priority:p0,priority:p1'
          exempt-pr-labels: 'pinned,security,wip'

  lock-resolved:
    needs: stale
    steps:
      - uses: dessant/lock-threads@{SHA}
        with:
          issue-inactive-days: 30
          pr-inactive-days: 30
```

### 6.6 标签体系(命名规范)

OpenCI 推荐以下标签命名规范:

| 命名空间 | 取值 | 说明 |
| --- | --- | --- |
| `type:` | bug/feature/docs/chore/question | 必有,描述类型 |
| `area:` | frontend/backend/infra/db/ai/docs | 必有,描述影响领域 |
| `priority:` | p0/p1/p2/p3 | 必有,AI triage 自动打 |
| `status:` | needs-triage/needs-info/in-progress/blocked/stale | 流转状态 |
| `size:` | xs/s/m/l/xl | PR 大小,自动打 |
| 特殊 | good-first-issue/help-wanted/pinned/security/breaking-change | 用于过滤和路由 |

每个 issue 至少有 `type:` + `area:` + `priority:` 三个标签,便于过滤和统计。

### 6.7 PR ↔ Issue 联动(v1.3 强化)

PR 描述里的 `Closes #N` / `Fixes #N` / `Resolves #N` 是流程的关键节点:

- merge 后 GitHub 自动关闭关联 issue
- release-drafter 把 issue 标题 + reporter 写入 changelog
- 项目板自动把 issue 卡片移到 Done

`actions/pr/validate-pr-description/action.yml`(v1.3 新增):检查 PR 描述必须满足以下之一:

- 包含 `Closes #N` / `Fixes #N` / `Resolves #N`
- 或 PR 标记了 `no-issue` label(明确说明无关联 issue,如纯 chore)

不满足则 PR check 失败,阻断合并。

---

## 七、外部服务集成(v1.3 新增)

外部 SaaS 服务通过专用原子 action 集成,统一放在 `actions/integrations/` 目录。每个集成都是可选的,消费方通过 input 开关启用,通过 secret 传递认证凭证。

### 7.1 集成总览

| 服务 | 角色 | 集成点 | 必要性 |
| --- | --- | --- | --- |
| Sentry | 错误追踪 + 发布通知 | prd.yml(release + error-check)、stg.yml | 强烈推荐 |
| SonarCloud | 代码质量门 | pr.yml | 推荐(开源免费) |
| PostHog | 产品分析 + LLM 可观测 | stg.yml / prd.yml(deploy 事件) | AI 项目推荐 |
| Snyk | 漏洞扫描(替代/补充) | pr.yml | 商业项目可选 |
| Slack | 通知 | ci/stg/prd 失败 + 发布完成 | 强烈推荐 |
| Linear | Issue tracker 同步 | community.yml(链接验证) | 用 Linear 时启用 |

### 7.2 Sentry 集成

Sentry 在 OpenCI 中承担两个角色:

**角色一:发布通知**

每次部署后,通知 Sentry 创建新 release,关联 commit 范围,自动上传 source map(若适用)。

`actions/integrations/sentry-release/action.yml`:

```yaml
inputs:
  environment:       { required: true }   # staging | production
  version:           { required: true }   # 推荐用 image-digest 或 git-sha
  source-maps-path:  { required: false }  # 仅前端项目需要
  sentry-org:        { required: true }
  sentry-project:    { required: true }

runs:
  using: composite
  steps:
    - uses: getsentry/action-release@{SHA}
      env:
        SENTRY_AUTH_TOKEN: ${{ inputs.sentry-token }}
        SENTRY_ORG: ${{ inputs.sentry-org }}
        SENTRY_PROJECT: ${{ inputs.sentry-project }}
      with:
        environment: ${{ inputs.environment }}
        version: ${{ inputs.version }}
        sourcemaps: ${{ inputs.source-maps-path }}
        finalize: true
```

**集成点**:

- stg.yml `notify-deployed`:创建 staging release
- prd.yml `create-release`:创建 production release

**角色二:观察窗口质量门**

`observe-window` 不应该仅仅 sleep,真正有价值的是观察期内的错误率。`check-error-rate` 通过 Sentry API 查询 STG 环境错误率,异常则阻断 PRD 部署。

### 7.3 SonarCloud 集成

SonarCloud 提供代码质量分析,在 pr.yml 中作为质量门,在 PR 上做 decoration(覆盖率、新增 bug、code smell)。

`actions/pr/scan-sonarcloud/action.yml`:

```yaml
inputs:
  sonar-organization: { required: true }
  sonar-project-key:  { required: true }
  sonar-host-url:     { required: false, default: "https://sonarcloud.io" }

runs:
  using: composite
  steps:
    - uses: SonarSource/sonarcloud-github-action@{SHA}
      env:
        GITHUB_TOKEN:  ${{ secrets.GITHUB_TOKEN }}
        SONAR_TOKEN:   ${{ inputs.sonar-token }}
      with:
        args: >
          -Dsonar.organization=${{ inputs.sonar-organization }}
          -Dsonar.projectKey=${{ inputs.sonar-project-key }}
          -Dsonar.host.url=${{ inputs.sonar-host-url }}
```

**PR 效果**:SonarCloud bot 评论显示 New Code 的 quality gate 状态、新增 bug/vulnerability/code smell,链接到详情页。

**与 Codecov 的关系**:

| 关注点 | Codecov | SonarCloud |
|--------|---------|------------|
| 覆盖率 | 强 | 一般 |
| 代码异味 | x | 安全漏洞 |
| Quality gate | 有 | 更复杂 |
| 公开仓库 | 免费 | 免费 |

两者职责重叠不多,通常一起用:Codecov 管覆盖率,SonarCloud 管代码异味 + 漏洞。

### 7.4 PostHog 集成(AI 项目特别推荐)

PostHog 是产品分析 + LLM 可观测性平台,对 AI 项目有独特价值:

- 产品分析(用户行为)
- LLM 调用追踪(token 用量、延迟、错误率)
- Feature flag 管理
- A/B 测试

`actions/integrations/posthog-event/action.yml`:

```yaml
inputs:
  api-key:     { required: true }
  event:       { required: true }    # deploy / release / hotfix
  environment: { required: true }
  version:     { required: true }
  properties:  { required: false }   # 额外 JSON 属性

runs:
  using: composite
  steps:
    - shell: bash
      run: |
        BODY=$(jq -n \
          --arg key "${{ inputs.api-key }}" \
          --arg event "${{ inputs.event }}" \
          --arg env "${{ inputs.environment }}" \
          --arg ver "${{ inputs.version }}" \
          --argjson extra '${{ inputs.properties || "{}" }}' \
          '{
            api_key: $key,
            event: $event,
            distinct_id: "ci-system",
            properties: ($extra + {
              environment: $env,
              version: $ver,
              source: "github-actions"
            })
          }')

        curl -X POST https://app.posthog.com/capture/ \
          -H "Content-Type: application/json" \
          -d "$BODY"

        echo "::notice title=PostHog Event::event=${{ inputs.event }} env=${{ inputs.environment }}"
```

**集成点**:

- stg.yml `notify-deployed`: `event=deploy`, `environment=staging`
- prd.yml `create-release`: `event=release`, `environment=production`

**效果**:PostHog 时间线上标记 deployment,后续可将 user behavior change 与 deployment 时间点关联分析。

### 7.5 Slack 通知集成

部署、发布、CI 失败的通知统一通过 Slack。

`actions/integrations/slack-notify/action.yml`:

```yaml
inputs:
  webhook-url: { required: true }
  status:      { required: true }    # success | failure | warning
  title:       { required: true }
  message:     { required: true }
  context:     { required: false }   # 额外 key-value 字段

runs:
  using: composite
  steps:
    - uses: slackapi/slack-github-action@{SHA}
      with:
        webhook: ${{ inputs.webhook-url }}
        webhook-type: incoming-webhook
        payload: |
          {
            "blocks": [
              {
                "type": "header",
                "text": { "type": "plain_text", "text": "${{ inputs.title }}" }
              },
              {
                "type": "section",
                "text": { "type": "mrkdwn", "text": "${{ inputs.message }}" }
              },
              {
                "type": "context",
                "elements": [
                  {
                    "type": "mrkdwn",
                    "text": "Repo: <${{ github.server_url }}/${{ github.repository }}|${{ github.repository }}> · Run: <${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}|#${{ github.run_number }}>"
                  }
                ]
              }
            ]
          }
```

**集成点**(按需通知,避免噪音):

- pr.yml 失败:不通知(开发者自己看)
- ci.yml 失败: `#ci-alerts`
- stg.yml 完成: `#deploys`
- prd.yml 完成: `#releases` + `#engineering`
- security-schedule 发现高危 CVE: `#security`

### 7.6 Snyk 集成(可选)

Snyk 是 dependency-review + Trivy 的替代/补充。如果团队已有 Snyk 订阅,可以加上获得更高质量的漏洞数据库和修复建议。

`actions/pr/scan-snyk/action.yml`:

```yaml
inputs:
  language:    { required: true }    # node | python | java | go
  severity:    { required: false, default: "high" }

runs:
  using: composite
  steps:
    - uses: snyk/actions/${{ inputs.language }}@{SHA}
      env:
        SNYK_TOKEN: ${{ inputs.snyk-token }}
      with:
        args: --severity-threshold=${{ inputs.severity }}
```

**与原有扫描工具关系**:

| 工具 | 扫描对象 | 数据库质量 | 价格 |
|------|---------|-----------|------|
| dependency-review | PR diff 的依赖 | GitHub Advisory | 免费 |
| Trivy | 文件系统 + 镜像 | 多源 | 免费 |
| Snyk | 依赖 + IaC + 容器 | 自有数据库,质量高 | 收费(开源免费) |

推荐策略:开源项目用 dependency-review + Trivy 足够;商业项目加 Snyk 获得更好的修复建议。

### 7.7 Linear 集成(若使用)

Linear 是 issue tracker,与 GitHub 双向同步通常通过 Linear 官方 GitHub App 实现,OpenCI 不需要重复造轮子。

但可以在 `community.yml` 中加一个 link 检查:

`actions/integrations/linear-link/action.yml`:

```yaml
# 检查 PR 描述或 branch name 中是否包含 LIN-XXX 编号
# 不包含则评论提醒
```

### 7.8 可观测性双模式架构(v1.5 新增)

外部服务集成按数据流方向分为两个完全不同的模式,放在不同目录:

| 模式 | 目录 | 数据流 | 失败策略 | 典型场景 |
| --- | --- | --- | --- | --- |
| **Push(部署标记)** | `actions/integrations/` | 单向推送事件 | `continue-on-error: true`(不影响部署) | Sentry release、Datadog deployment event |
| **Pull(健康报告)** | `actions/observability/` | 拉取数据 + AI 合成 | 失败返回 `{"_error":"..."}` partial JSON | 每日健康日报、错误分诊 |

**为什么分开**:Push 是"告诉外部服务一件事"(部署了),Pull 是"从外部服务拉数据 + 处理"(汇总报告)。意图和数据流向不同,放一起会让 action 列表变难懂。

#### 7.8.1 Push 模式:Deployment Marker

每个服务接收"有新版本上线了"这个事件的方式不同:

| 服务 | 推送方式 | 已有 action |
| --- | --- | --- |
| Sentry | 创建 release | `getsentry/action-release` |
| Datadog | submit deployment event | 无,直接 `curl POST /api/v1/events` |
| PostHog | capture 自定义事件 | 无,直接 `curl POST /capture/` |
| LangSmith | 给后续 traces 打 deployment 元数据标签 | 无,`curl POST runs` 端点 |
| Axiom | 写一条 deployment log | 无,`curl POST /v1/datasets/{ds}/ingest` |

`actions/integrations/notify-deploy/action.yml`(Composite,扇出到上面 5 个原子):

```yaml
inputs:
  environment:     { required: true }    # staging | production
  version:         { required: true }    # image-digest 或 git-sha
  git-sha:         { required: true }
  enable-sentry:   { required: false, default: "true" }
  enable-datadog:  { required: false, default: "false" }
  enable-posthog:  { required: false, default: "true" }
  enable-langsmith:{ required: false, default: "false" }
  enable-axiom:    { required: false, default: "false" }

runs:
  using: composite
  steps:
    # 每个原子内部 timeout 30s + 失败静默
    # 单服务故障不影响其他服务
    - if: inputs.enable-sentry == 'true'
      uses: ./actions/integrations/sentry-release
      continue-on-error: true
      with:
        environment: ${{ inputs.environment }}
        version: ${{ inputs.version }}

    - if: inputs.enable-datadog == 'true'
      uses: ./actions/integrations/datadog-event
      continue-on-error: true
      with:
        environment: ${{ inputs.environment }}
        version: ${{ inputs.version }}

    - if: inputs.enable-posthog == 'true'
      uses: ./actions/integrations/posthog-event
      continue-on-error: true
      with:
        event: deploy
        environment: ${{ inputs.environment }}
        version: ${{ inputs.version }}

    - if: inputs.enable-langsmith == 'true'
      uses: ./actions/integrations/langsmith-tag
      continue-on-error: true
      with:
        version: ${{ inputs.version }}

    - if: inputs.enable-axiom == 'true'
      uses: ./actions/integrations/axiom-event
      continue-on-error: true
      with:
        environment: ${{ inputs.environment }}
        version: ${{ inputs.version }}
```

**关键设计点**:

- `continue-on-error: true`:推送失败绝不能阻断部署。Sentry 挂了不能让你回滚 prd。
- 每个原子内部 `timeout 30s` + 失败静默:单服务故障不影响其他服务。
- fan-out 在 composite 而非 workflow:符合"workflow → composite → atom"层级。
- 共用 metadata 输入:`environment`、`version`、`git-sha` 是所有服务都需要的字段,在 composite 层统一接收一次。

**调用方式**(stg.yml / prd.yml 末尾):

```yaml
- name: Notify observability stack
  uses: ./actions/integrations/notify-deploy
  continue-on-error: true
  with:
    environment: production
    version: ${{ inputs.image-digest }}
    git-sha: ${{ github.sha }}
    enable-sentry: true
    enable-datadog: true
    enable-posthog: true
  env:
    SENTRY_AUTH_TOKEN: ${{ secrets.SENTRY_TOKEN }}
    DD_API_KEY: ${{ secrets.DATADOG_API_KEY }}
    POSTHOG_API_KEY: ${{ secrets.POSTHOG_API_KEY }}
```

#### 7.8.2 Pull 模式:Health Report(Collect → Synthesize → Publish)

定时从外部服务拉数据 + Claude 合成日报,三步走:

`.github/workflows/health-report.yml`:

```yaml
on:
  schedule:
    - cron: '0 1 * * 1-5'   # 工作日北京时间 09:00
  workflow_dispatch:

jobs:
  collect:
    runs-on: ubuntu-latest
    steps:
      - uses: ./actions/observability/collect-all
        id: data
        # 串行调用 query-sentry / query-datadog / query-posthog / query-langsmith / query-axiom
        # 每个 query-* 返回固定 schema 的 JSON
        # 失败时返回 {"_error": "...", "_partial": true},Claude 在数据缺失时也能继续

  synthesize:
    needs: collect
    uses: ./.github/workflows/claude-harness.yml
    with:
      task: daily-health-report
      prompt-path: prompts/observability/daily-health-report.md
      context: ${{ needs.collect.outputs.data }}

  publish:
    needs: synthesize
    runs-on: ubuntu-latest
    steps:
      - uses: ./actions/observability/publish-report
        with:
          report: ${{ needs.synthesize.outputs.result }}
          # 同时发 GitHub Issue + Slack #daily-health 频道
```

**每个服务拉什么数据(初始建议)**:

| 服务 | 拉取内容 |
|------|---------|
| Sentry | 过去 24h 错误总数 / Top 5 错误类型 / 错误率趋势 |
| Datadog | p50/p95/p99 延迟 / 错误率 / 关键 metric 异常 |
| PostHog | DAU / 关键漏斗转化率 / 异常事件 |
| LangSmith | LLM 调用量 / 总成本 USD / token 用量 / Top 失败 prompt |
| Axiom | 错误日志条数 / Top error pattern |

**Claude 输出结构**(固定格式,便于 issue 标题摘录、Slack 卡片渲染):

```markdown
# Daily Health Report - {{date}}

## TL;DR
- (3-5 条最重要的事)

## 需要关注
- (异常/退化项)

## 关键指标
| 指标 | 今日 | 昨日 | 趋势 |
| --- | --- | --- | --- |
| ... |

## LLM 用量与成本
- 总成本 / token 分布 / Top 失败

## 建议行动项
1. ...
```

---

## 八、可观测性 Annotation 规范

所有关键步骤输出标准化 GitHub Actions annotation:

| 场景 | 级别 | 格式 |
|------|------|------|
| 语言检测结果 | notice | `::notice title=Language Detected::language=$L pkg-mgr=$PM` |
| 镜像构建完成 | notice | `::notice title=Image Built::digest=$D size=${S}MB` |
| 镜像签名完成 | notice | `::notice title=Image Signed::digest=$D` |
| Eval 结果 | notice | `::notice title=Eval Result::passed=$P/$T score=$S` |
| 版本对齐通过 | notice | `::notice title=Version Aligned::digest=$D ✓` |
| 版本对齐失败 | error | `::error title=Version Mismatch::prd=$P stg=$S` |
| 观察窗口状态 | notice | `::notice title=Observation Window::elapsed=${E}min required=${R}min` |
| CVE 发现 | warning | `::warning title=CVE Found::$ID severity=$SEV package=$PKG` |
| 部署完成 | notice | `::notice title=Deployed::env=$ENV digest=$D time=$T` |
| 测试失败 | error | `::error file=$FILE,line=$LINE::Test failed: $MSG` |

---

## 九、安全规范

### 7.1 SHA 固定操作

**原则**:所有 action 文件中的第三方 `uses:` 必须引用 `manifest.yml` 中的 SHA。

**Action 文件读取 SHA 的方式**:

```yaml
steps:
  - id: manifest
    uses: ./actions/_common/read-manifest
  
  - uses: ${{ fromJson(steps.manifest.outputs.deps)['actions/checkout'] }}
    with:
      fetch-depth: 0
```

**批量检查**:
```bash
npx pin-github-action .github/workflows/*.yml actions/**/*.yml
```

**Renovate 配置**（`.github/renovate.json`）:
```json
{
  "extends": ["config:base"],
  "packageRules": [{
    "matchManagers": ["github-actions"],
    "updateType": "pinDigest",
    "automerge": false,
    "labels": ["deps", "security"]
  }]
}
```

### 7.2 权限最小化矩阵

每个工作流在 job 级别声明 `permissions`:

| 工作流 | contents | pull-requests | security-events | id-token | packages | issues |
|--------|----------|---------------|-----------------|----------|----------|--------|
| claude-harness | read | write | - | write | - | write |
| pr.yml | read | write | write | write | - | - |
| ci.yml | read | - | write | write | write | - |
| stg.yml | read | - | - | write | read | - |
| prd.yml | read | write | - | write | read | - |
| security-schedule | read | - | write | - | - | - |
| community.yml | read | write | - | - | - | write |

**全局默认**:工作流顶层 `permissions: {}` 拒绝所有,job 级别精确授权。

### 7.3 已淘汰 action 处理（v1.3 新增）

以下 action 因安全或维护原因被淘汰,禁止在新工作流中使用:

| action | 淘汰原因 | 替代方案 |
|--------|---------|---------|
| `semgrep/semgrep-action` | 2020 年停更,不再维护 | CLI: `pip install semgrep && semgrep ci` |
| `amondnet/vercel-action` | 版本严重滞后(v25 vs 最新 v42.3.0) | 官方 Vercel CLI: `npm i -g vercel && vercel deploy --prod` |
| `trufflesecurity/trufflehog@main` | 引用 `main` 分支,供应链风险 | 固定到发布版本 SHA(`manifest.yml` 中维护) |

**迁移策略**:已有工作流中的淘汰 action 逐步替换,优先级 P0（安全相关）> P1（功能替代）。替换时同步更新 `manifest.yml` 中的 SHA。

### 7.4 harden-runner 统一配置

每个工作流的每个 job 第一步:

```yaml
steps:
  - name: Harden runner
    uses: step-security/harden-runner@{SHA}
    with:
      egress-policy: audit
      # 稳定后切 block 模式:
      # egress-policy: block
      # allowed-endpoints: >
      #   api.anthropic.com:443
      #   ghcr.io:443
      #   api.github.com:443
```

---

## 十、Codecov 集成

**文件**:`actions/pr/check-coverage/action.yml`

**触发时机**:pr.yml 中 `test` job 上传 coverage artifact 后

**输入**:
```yaml
inputs:
  codecov-token: { required: false }
  coverage-threshold: { default: "80" }
  flags: { default: "unit" }
```

**实现**:
```yaml
- uses: codecov/codecov-action@{SHA}
  with:
    token: ${{ inputs.codecov-token }}
    threshold: ${{ inputs.coverage-threshold }}
    fail_ci_if_error: true
    flags: ${{ inputs.flags }}
    name: ${{ github.repository }}-${{ github.sha }}
    comment_type: "pr"
```

**PR 效果**:Codecov bot 评论显示覆盖率变化（`+2.3% / -1.1%`）、未覆盖的新增代码行。

---

## 十一、MegaLinter 多语言统一 Lint(v1.3 新增)

**文件**：`actions/pr/lint-code/action.yml`

**职责**：统一执行多语言静态检查，替代按语言分别实现 linter 的方式。消费方无需关心具体语言栈，MegaLinter 自动检测并路由。

**为什么用 MegaLinter 而非按语言拆分**：

| 方案 | 优势 | 劣势 |
|------|------|------|
| 按语言拆分(lint-node/lint-python/…) | 精确控制,轻量 | 新增语言需新建 action,消费方需指定语言 |
| **MegaLinter(采用)** | 自动检测语言,85+ linter 开箱即用,统一配置 | Docker 镜像较大,可用 flavor 精简 |

**输入**：
```yaml
inputs:
  mega-linter-flavor:  { default: "all", description: "精简镜像: python|javascript|go|java|all" }
  config-file:         { default: ".megalinter.yml", description: "消费方自定义配置路径" }
  fail-on-error:       { default: "true" }
```

**实现**：
```yaml
steps:
  - name: MegaLinter
    uses: oxsecurity/megalinter@{SHA}
    env:
      MEGALINTER_FLAVOR: ${{ inputs.mega-linter-flavor }}
      MEGALINTER_CONFIG_FILE: ${{ inputs.config-file }}
      VALIDATE_ALL_CODEBASE: false  # 仅检查 PR diff
      GITHUB_TOKEN: ${{ github.token }}
```

**Flavor 选择策略**（基于 detect-language 输出自动路由）：

| detect-language 输出 | flavor | 镜像大小 |
|---------------------|--------|---------|
| node | `javascript` | ~200MB |
| python | `python` | ~250MB |
| go | `go` | ~180MB |
| java | `java` | ~300MB |
| unknown/多语言 | `all` | ~800MB |

**消费方自定义**（`.megalinter.yml`）：
```yaml
# 消费方仓库根目录放置,覆盖默认配置
ENABLE:
  - PYTHON
  - JAVASCRIPT
  - YAML
  - DOCKERFILE
  - MARKDOWN
DISABLE:
  - COPYPASTE  # 禁用重复代码检测
PYTHON_RUFF_CONFIG_FILE: ".ruff.toml"  # 指向消费方已有配置
```

**Annotation**：
```bash
echo "::notice title=Lint Passed::flavor=$FLAVOR errors=0 warnings=$WARNINGS"
echo "::error title=Lint Failed::errors=$ERRORS files=$FILES"
```

---

## 十二、容器安全扫描(v1.3 新增)

**文件**：`actions/ci/scan-image/action.yml`

**职责**：对构建完成的 Docker 镜像执行 CVE 扫描，结果上报 GitHub Security tab。

**输入**：
```yaml
inputs:
  image-ref:     { required: true, description: "镜像引用,如 ghcr.io/owner/app:sha-abc1234" }
  severity:      { default: "CRITICAL,HIGH" }
  exit-code:     { default: "1", description: "发现漏洞时的退出码,1=阻断" }
  format:        { default: "sarif" }
```

**实现**：
```yaml
steps:
  - name: Run Trivy vulnerability scanner
    uses: aquasecurity/trivy-action@{SHA}
    with:
      image-ref: ${{ inputs.image-ref }}
      format: ${{ inputs.format }}
      output: trivy-results.sarif
      severity: ${{ inputs.severity }}
      exit-code: ${{ inputs.exit-code }}

  - name: Upload Trivy scan results to GitHub Security tab
    uses: github/codeql-action/upload-sarif@{SHA}
    if: always()
    with:
      sarif_file: trivy-results.sarif
```

**双扫模式**（ci.yml 中）：

1. **fs 扫描**：构建前扫描文件系统依赖（`trivy fs .`），提前发现漏洞
2. **image 扫描**：构建后扫描镜像（`trivy image`），覆盖 OS 层漏洞

**Annotation**：
```bash
echo "::warning title=CVE Found::$CVE_ID severity=$SEVERITY package=$PKG"
echo "::notice title=Image Scan Passed::image=$IMAGE_REF severity=$SEVERITY ✓"
```

---

## 十三、CodeQL 集成

**文件**:`actions/security/scan-codeql/action.yml`

**输入**:
```yaml
inputs:
  language: { required: true }   # javascript-typescript | python | go | java
  query-suite: { default: "security-extended" }
```

**实现**（三步固定模式）:
```yaml
steps:
  - uses: github/codeql-action/init@{SHA}
    with:
      languages: ${{ inputs.language }}
      queries: ${{ inputs.query-suite }}

  - uses: github/codeql-action/autobuild@{SHA}

  - uses: github/codeql-action/analyze@{SHA}
    with:
      category: "/language:${{ inputs.language }}"
      upload: true
```

---

## 十四、版本管理与发布

### 14.1 语义化版本

```
v{MAJOR}.{MINOR}.{PATCH}

MAJOR:破坏性变更（输入/输出接口变更,消费方需修改引用）
MINOR:新增功能（向后兼容）
PATCH:Bug 修复（行为不变）
```

**主版本 tag 浮动**:`v2` 始终指向 `v2.x.x` 最新版,消费方引用 `@v2` 自动获得非破坏性更新。

### 14.2 release-drafter 配置

```yaml
# .github/release-drafter.yml
name-template: 'v$RESOLVED_VERSION'
tag-template: 'v$RESOLVED_VERSION'
template: |
  ## 变更内容
  $CHANGES
  
  ## 消费方升级
  ```yaml
  uses: org/opencl/.github/workflows/pr.yml@v$MAJOR_VERSION
  ```
categories:
  - title: '破坏性变更'
    labels: ['breaking-change']
  - title: '新功能'
    labels: ['feature', 'enhancement']
  - title: '修复'
    labels: ['bug', 'fix']
  - title: '安全'
    labels: ['security', 'deps']
version-resolver:
  major: { labels: ['breaking-change'] }
  minor: { labels: ['feature', 'enhancement'] }
  patch: { labels: ['bug', 'fix', 'security', 'deps'] }
  default: patch
```

---

## 十五、消费方集成示例

### 15.1 最简集成(Node.js)

```yaml
# .github/workflows/pr.yml（消费方仓库）
name: PR
on:
  pull_request:
    types: [opened, synchronize, reopened]

jobs:
  quality:
    uses: your-org/opencl/.github/workflows/pr.yml@v2
    with:
      enable-ai-review: true
    secrets:
      anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
      codecov-token: ${{ secrets.CODECOV_TOKEN }}
```

### 15.2 完整 CI/CD 链路

```yaml
# .github/workflows/ci.yml（消费方仓库）
name: CI & Deploy
on:
  push:
    branches: [main]

jobs:
  build:
    uses: your-org/opencl/.github/workflows/ci.yml@v2
    with:
      image-name: my-app
      run-migration: true
    outputs:
      image-digest: ${{ jobs.build.outputs.image-digest }}
      deploy-time: ${{ jobs.build.outputs.deploy-time }}
    secrets:
      registry-token: ${{ secrets.GITHUB_TOKEN }}

  deploy-stg:
    needs: build
    uses: your-org/opencl/.github/workflows/stg.yml@v2
    with:
      image-digest: ${{ needs.build.outputs.image-digest }}
      run-migration: true
    outputs:
      deploy-time: ${{ jobs.deploy-stg.outputs.deploy-time }}
    secrets:
      kubeconfig-stg: ${{ secrets.KUBECONFIG_STG }}

  deploy-prd:
    needs: [build, deploy-stg]
    uses: your-org/opencl/.github/workflows/prd.yml@v2
    with:
      image-digest: ${{ needs.build.outputs.image-digest }}
      stg-image-digest: ${{ needs.build.outputs.image-digest }}
      stg-deploy-time: ${{ needs.deploy-stg.outputs.deploy-time }}
      observation-minutes: 30
      run-migration: true
    secrets:
      kubeconfig-prd: ${{ secrets.KUBECONFIG_PRD }}
```

### 15.3 自定义 Prompt 覆盖(无需 Fork)

```yaml
jobs:
  quality:
    uses: your-org/opencl/.github/workflows/pr.yml@v2
    with:
      pr-review-prompt-path: .agents/skills/my-project-review.md
```

### 15.4 AI 项目扩展

```yaml
jobs:
  quality:
    uses: your-org/opencl/.github/workflows/pr.yml@v2
    with:
      enable-ai-review: true
      enable-eval: true          # prompt 变更时自动跑回归 eval
    secrets:
      anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}

  build:
    uses: your-org/opencl/.github/workflows/ci.yml@v2
    with:
      image-name: my-ai-app
      enable-ai-smoke: true      # merge 后用真实镜像跑冒烟 eval
    secrets:
      anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
```

---

## 十六、Aicert CI/CD 对比分析(v1.4 新增)

本章基于 [aicert](https://github.com/YiAgent/aicert) 仓库的 `CI-CD-FLOW-MAP.md` 和 `CICD_PIPELINE_DESIGN.md` 设计文档,逐项对比 OpenCI 当前能力,列出可补充或升级的功能差距。每项标注优先级(P0 立即补充/P1 高价值扩展/P2 按需引入)。

### 16.1 架构层差距

| # | 特性 | Aicert 实现 | OpenCI 现状 | 价值 | 优先级 |
| --- | --- | --- | --- | --- | --- |
| 1 | Issue→Branch 自动化 | `pr-branch-from-issue.yml` 由 Linear webhook `repository_dispatch` 触发,自动创建 `feat/aic-NNN-slug` 分支并回写 Linear 评论 | 无此流程 | 开发者不用手动建分支,issue 状态驱动分支创建 | P2 |
| 2 | workflow_run 跨工作流聚合 | `pr-agent-summary` 订阅 8 个 workflow 的 `workflow_run` 完成事件 + 外部 App 的 `check_suite`,upsert 单条带 `<!-- pr-summary-bot -->` marker 的滚动评论 | 各 workflow 独立报告,无聚合机制 | PR 上只有一条汇总评论,不刷屏;开发者一眼看到所有检查结果 | P1 |
| 3 | Concurrency Groups 完整策略 | 每个 workflow 定义 `concurrency.group` + `cancel-in-progress` 策略:PR 类=cancel(yes),deploy/ops 类=no(避免中断部署) | 未定义 concurrency 策略 | 避免同一 PR 多次 push 产生重复 run 浪费 runner 分钟 | P0 |
| 4 | Ops 运维工作流 | `ops-flag-audit`(周一 15:00)、`ops-health-report`(每日 09:00)、`ops-agent-triage`(每小时)三个 cron 工作流持续监控 | 无 ops 层工作流 | 持续监控生产环境健康、自动分诊错误、审计 feature flag | P1 |
| 5 | Agent 反馈闭环 | `pr-agent-feedback` 识别 PR 作者是 `copilot-swe-agent[bot]` 或分支名 `codex/` 前缀 → CI 失败时自动 @-mention agent 附失败日志让其修复 | 无 agent 识别和自动修复 | AI agent 开的 PR 能自愈,减少人工干预 | P2 |

#### 16.1.1 Concurrency Groups 规格参考

```yaml
# PR 类 workflow: 同一 PR 新 push 取消旧 run
concurrency:
  group: pr-verify-${{ github.event.pull_request.number }}
  cancel-in-progress: true

# Deploy 类 workflow: 不取消,避免中断正在进行的部署
concurrency:
  group: deploy-stg-${{ github.ref }}
  cancel-in-progress: false

# Ops 类 workflow: 不取消,确保每次 cron 都执行
concurrency:
  group: error-triage
  cancel-in-progress: false
```

#### 16.1.2 workflow_run 聚合规格参考

```yaml
on:
  workflow_run:
    workflows:
      - "PR: Verify"
      - "PR: Security Scan"
      - "PR: Code Quality"
      - "PR: Build Check"
      - "Stg: Deploy"
      - "Prd: Deploy"
    types: [completed]
  check_suite:
    types: [completed]
```

聚合逻辑:poll 直到所有 check settle(10 分钟上限),构建综合摘要,upsert 单条滚动评论。

### 16.2 安全与质量门禁

| # | 特性 | Aicert 实现 | OpenCI 现状 | 价值 | 优先级 |
| --- | --- | --- | --- | --- | --- |
| 6 | Secrets Preflight | `preflight-secrets.sh` → `preflight-secrets.py` 在每个 workflow 开头 live-probe 所有必需 secret,缺失则快速 fail | 无预检机制 | 缺 secret 时快速 fail,不浪费 runner 时间跑一半才发现 | P0 |
| 7 | graceful-skip 模式 | 7 个安全扫描器全部支持 token 缺席 → exit 0,PR 不被无关原因阻塞 | 未定义 graceful-skip | 新环境没配好 GITGUARDIAN_API_KEY/SNYK_TOKEN 时 PR 不卡住 | P0 |
| 8 | coverage 阶段门槛 | PR 阶段警告不阻塞(允许新功能先合),Stg 阶段 < 60% 阻塞部署 | 只有 PR 阶段 coverage | 防止覆盖率持续下降,同时不阻塞开发速度 | P1 |
| 9 | 环境变量漂移守卫 | CI 校验 `validate-env.sh` 覆盖所有 `@groups:heroku` 变量,确保 CI 和运行时环境变量一致 | 无漂移检测 | 防止部署时缺环境变量导致启动失败 | P1 |
| 10 | Gitleaks artifact 扫描 | `stg-agent-test` reporter 用 gitleaks 扫描 triage 产物是否泄漏 secret | 无 artifact 扫描 | AI agent 产物可能包含敏感信息,需在开 issue 前检查 | P2 |

#### 16.2.1 graceful-skip 模式规格

```yaml
# 每个安全扫描 job 开头检查 token
- name: Check token
  id: check
  run: |
    if [ -z "${{ secrets.SNYK_TOKEN }}" ]; then
      echo "skip=true" >> $GITHUB_OUTPUT
    fi

- name: Run Snyk
  if: steps.check.outputs.skip != 'true'
  run: snyk test
```

#### 16.2.2 Secrets Preflight 规格

```yaml
- name: Preflight secrets
  run: |
    bash .github/scripts/preflight-secrets.sh \
      --required "DOPPLER_TOKEN,EC2_SSH_KEY,CODECOV_TOKEN" \
      --optional "GITGUARDIAN_API_KEY,SNYK_TOKEN"
```

### 16.3 部署与自愈

| # | 特性 | Aicert 实现 | OpenCI 现状 | 价值 | 优先级 |
| --- | --- | --- | --- | --- | --- |
| 11 | 部署回滚机制 | prd smoke/e2e 失败 → SSH `git reset` 到 snapshot SHA + `systemctl restart` + 开 Linear P1 incident | 无自动回滚 | 部署失败自动恢复,不等人工介入 | P1 |
| 12 | Canary Watch | `prd-canary-watch.yml` 每 15 分钟 Sentry 错误率 3σ 偏离 + ≥5 绝对量 → 自动回滚 + Linear P1 | 无 canary 监控 | 部署后 30 分钟内的持续保护,捕获延迟暴露的问题 | P2 |
| 13 | Prd Verify Fix | `prd-verify-fix.yml` 在 prd 部署成功后,对照 PR body 中 `Fixes #N` 标记去 Sentry 验证错误是否真的不再出现 | 无修复验证 | 区分"声称修了"和"真的修了",闭环 bug 修复 | P2 |
| 14 | Terraform Drift Check | prd 部署时 Stage 3.5 跑 `terraform plan` 只读检查基础设施漂移,advisory 模式 | 无基础设施漂移检测 | 发现手动改过的基础设施配置,防止配置偏移 | P2 |
| 15 | Tag 触发 prd | `git tag v*.*.*` = 发布意图,不用自动 promotion 也不用手工 approval;开发者显式决定发布时机 | 未定义 prd 触发策略 | 开发者控制发布节奏,避免 stg 全绿后意外推上 prd | P1 |

#### 16.3.1 回滚机制规格

```yaml
- name: Snapshot current prod SHA
  id: snapshot
  run: echo "sha=$(ssh $HOST 'git -C /app rev-parse HEAD')" >> $GITHUB_OUTPUT

- name: Rollback on failure
  if: failure()
  run: |
    ssh $HOST "cd /app && git reset --hard ${{ steps.snapshot.outputs.sha }} && systemctl restart app"
    gh issue create --title "P1: Production rollback" --label "incident,P1"
```

#### 16.3.2 Tag 触发策略

```yaml
on:
  push:
    tags:
      - "v*"

# 不用: on: workflow_run (auto-promotion)
# 不用: environment: production (manual approval)
# 打 tag 本身就是有意识的人工决策
```

### 16.4 可观测性

可观测性集成拆成两个职责完全不同的目标:

- **目标 1: 部署后推送** = 单向推送事件(deployment marker),失败不能影响部署本身
- **目标 2: 定时拉取 + 汇总** = 反向数据采集 + AI 合成,有完整的 collect → synthesize → publish pipeline

两件事用不同的目录和不同的设计模式。

#### 16.4.1 目标 1: 部署后推送 (Deployment Markers)

每个服务接收"有新版本上线了"这个事件的方式不同:

| 服务 | 推送方式 | 已有 action |
| --- | --- | --- |
| Sentry | 创建 release | `getsentry/action-release` ✓ |
| Datadog | submit deployment event | 无,直接 curl POST `/api/v1/events` |
| PostHog | capture 自定义事件 | 无,直接 curl POST `/capture/` |
| LangSmith | 给后续 traces 打 deployment 元数据标签 | 无,curl POST runs 端点 |
| Axiom | 写一条 deployment log | 无,curl POST `/v1/datasets/{ds}/ingest` |

**文件结构**(`actions/integrations/`):

```
actions/integrations/
├── sentry-release/        # 封装 getsentry/action-release
├── datadog-event/         # curl 自实现
├── posthog-event/         # curl 自实现(v1.3 已有)
├── langsmith-tag/         # curl 自实现
├── axiom-event/           # curl 自实现
└── notify-deploy/         # composite,按 input flag 扇出到上面 5 个原子
```

**调用方式** — stg.yml 和 prd.yml 部署成功后,通过 composite notify-deploy 一次性触发:

```yaml
# 在 stg.yml / prd.yml 末尾
- name: Notify observability stack
  uses: ./actions/integrations/notify-deploy
  continue-on-error: true              # ← 关键:推送失败不影响部署
  with:
    environment: production
    version: ${{ inputs.image-digest }}
    git-sha: ${{ github.sha }}
    enable-sentry: true
    enable-datadog: true
    enable-posthog: true
    enable-langsmith: true
    enable-axiom: false
  env:
    SENTRY_AUTH_TOKEN: ${{ secrets.SENTRY_TOKEN }}
    DD_API_KEY: ${{ secrets.DATADOG_API_KEY }}
    POSTHOG_API_KEY: ${{ secrets.POSTHOG_API_KEY }}
    LANGSMITH_API_KEY: ${{ secrets.LANGSMITH_API_KEY }}
```

**关键设计点**:

- **`continue-on-error: true`**: 推送失败绝不能阻断部署。Sentry 挂了不能让你回滚 prd。
- **每个原子内部 timeout 30s + 失败静默**: 单服务故障不影响其他服务。
- **fan-out 在 composite 而非 workflow**: 符合"workflow → composite → atom"层级。
- **共用 metadata 输入**: `environment`、`version`、`git-sha` 是所有服务都需要的字段,在 composite 层统一接收一次。

#### 16.4.2 目标 2: 定时拉取 + AI 汇总日报

三步走: collect → synthesize → publish,正好对应一个 workflow 的三个 job。

**文件结构**(`actions/observability/`):

```
actions/observability/
├── query-sentry/          # 拉 Sentry 数据 → JSON
├── query-datadog/         # 拉 Datadog 数据 → JSON
├── query-posthog/         # 拉 PostHog 数据 → JSON
├── query-langsmith/       # 拉 LangSmith 数据 → JSON
├── query-axiom/           # 拉 Axiom 数据 → JSON
├── collect-all/           # composite:串行调用全部 query-*
├── post-issue-report/     # 原子:把报告发成 GitHub Issue
├── post-slack-report/     # 原子:把报告发到 Slack
└── publish-report/        # composite:同时 post issue + slack
```

加 prompt:

```
prompts/observability/
└── daily-health-report.md   # 给 Claude 的合成指令
```

**工作流结构**(`.github/workflows/health-report.yml`):

```yaml
on:
  schedule: '0 1 * * 1-5'  # 工作日北京时间 09:00 (UTC+8 = UTC 01:00)
  workflow_dispatch:        # 手动触发

jobs:
  collect:
    runs-on: ubuntu-latest
    steps:
      - uses: ./actions/observability/collect-all
        # 内部串行调用全部 query-* 原子
        # 每个原子输出 JSON 到 outputs
        outputs:
          sentry-data: ${{ steps.collect.outputs.sentry-data }}
          datadog-data: ${{ steps.collect.outputs.datadog-data }}
          posthog-data: ${{ steps.collect.outputs.posthog-data }}
          langsmith-data: ${{ steps.collect.outputs.langsmith-data }}
          axiom-data: ${{ steps.collect.outputs.axiom-data }}

  synthesize:
    needs: collect
    uses: ./.github/workflows/claude-harness.yml
    with:
      task: daily-health-report
      prompt-path: prompts/observability/daily-health-report.md
      context: |
        {
          "sentry": ${{ needs.collect.outputs.sentry-data }},
          "datadog": ${{ needs.collect.outputs.datadog-data }},
          "posthog": ${{ needs.collect.outputs.posthog-data }},
          "langsmith": ${{ needs.collect.outputs.langsmith-data }},
          "axiom": ${{ needs.collect.outputs.axiom-data }}
        }
    outputs:
      report: ${{ steps.claude.outputs.result }}

  publish:
    needs: synthesize
    runs-on: ubuntu-latest
    steps:
      - uses: ./actions/observability/publish-report
        with:
          report: ${{ needs.synthesize.outputs.report }}
          # 内部并行调用 post-issue-report + post-slack-report
```

**每个 query-* 原子返回固定 schema 的 JSON**,失败时返回:

```json
{
  "_error": "Sentry API timeout after 30s",
  "_partial": true
}
```

让 Claude 在数据缺失时也能继续,而不是整体失败。

**每个服务拉什么数据(初始建议)**:

| 服务 | 采集指标 |
| --- | --- |
| Sentry | 过去 24h 错误总数 / Top 5 错误类型 / 错误率趋势 |
| Datadog | p50/p95/p99 延迟 / 错误率 / 关键 metric 异常 |
| PostHog | DAU / 关键漏斗转化率 / 异常事件 |
| LangSmith | LLM 调用量 / 总成本 USD / token 用量 / Top 失败 prompt |
| Axiom | 错误日志条数 / Top error pattern |

**Claude prompt 输出结构** — 固定 Markdown,便于 issue 标题摘录、Slack 卡片渲染:

```markdown
# 📊 Daily Health Report - {{date}}

## TL;DR
- (3-5 条最重要的事)

## 🚨 需要关注
- (异常/退化项)

## 📈 关键指标
| 指标 | 今日 | 昨日 | 趋势 |
| --- | --- | --- | --- |
| ... |

## 🤖 LLM 用量与成本
- 总成本 / token 分布 / Top 失败

## 💡 建议行动项
1. ...
```

### 16.5 开发体验

| # | 特性 | Aicert 实现 | OpenCI 现状 | 价值 | 优先级 |
| --- | --- | --- | --- | --- | --- |
| 20 | Local Git Hooks (lefthook) | `lefthook.yml` 定义 pre-commit(ruff/eslint/mypy/tsc + guard-no-main + guard-dotenv + guard-large-files)、commit-msg(conventional commit)、pre-push(env 校验) | 无本地 hook | 90% lint 问题在 push 前消灭,节省 CI 等待时间 | P0 |
| 21 | PR Templates | `.github/PULL_REQUEST_TEMPLATE/default.md` + `cherry_pick.md` 标准化 PR 描述 | 无 PR 模板 | PR 描述标准化,AI 和人工审查都能获取结构化上下文 | P0 |
| 22 | Dependabot Auto-Merge | `dep-auto-merge.yml` 对 Dependabot PR 分级:patch/dev-minor 自动合并,major/runtime-minor 人工审查 | 无自动合并 | 低风险依赖升级零干预,高风险升级保留人工审查 | P1 |
| 23 | 性能基线 (Blackfire) | Stg 部署 Stage 1.5 跑 `tests/perf/` perf scenario,`continue-on-error: true` soft-gate,3-4 周后阈值稳定切硬门槛 | 无性能基线 | 性能回归早期发现,不阻塞当前部署 | P2 |
| 24 | Environment Matrix | 集中管理所有环境变量:Doppler 管应用变量,GitHub Secrets 只存 CI infra 变量,`infra/ENV_MATRIX.md` 文档化 | 未定义变量管理策略 | 避免 secret 散落各处,新人入职一目了然 | P1 |

#### 16.5.1 lefthook.yml 规格参考

```yaml
pre-commit:
  parallel: true
  commands:
    guard-no-main-commit:
      run: test "$(git branch --show-current)" != "main" || exit 1
    guard-dotenv:
      run: git diff --cached --name-only | grep -q '\.env$' && exit 1 || exit 0
    guard-large-files:
      run: git diff --cached --name-only --diff-filter=A | xargs -I{} sh -c 'test $(wc -c < "{}") -gt 512000 && exit 1'
    ruff-check:
      run: ruff check --fix {staged_files}
    ruff-format:
      run: ruff format {staged_files}
    eslint:
      run: eslint --fix {staged_files}
    mypy:
      run: mypy app/
    tsc:
      run: tsc --noEmit

commit-msg:
  commands:
    conventional-commit:
      run: head -1 "$1" | grep -qE '^(feat|fix|refactor|docs|test|chore|perf|ci|build|style)(\(.+\))?: .{1,}' || exit 1
```

#### 16.5.2 PR Template 规格

```markdown
## Summary
<!-- 1-3 bullet points describing what this PR does -->

## Test plan
- [ ] Unit tests added/updated
- [ ] Manual testing completed

## Related issues
<!-- Fixes #N / Closes #N -->
```

### 16.6 AI Agent 增强

| # | 特性 | Aicert 实现 | OpenCI 现状 | 价值 | 优先级 |
| --- | --- | --- | --- | --- | --- |
| 25 | Agent Test Gen | `pr-agent-test-gen.yml` 读 PR diff → AI 生成单测骨架并 commit 到 PR 分支 | 无自动测试生成 | 自动补测试,提高覆盖率 | P2 |
| 26 | Stg Autonomous Test | `stg-agent-test.yml` 在 stg 部署成功后 `workflow_run` 触发,L1-L4 AI agent 对 live stg 跑自主测试(schema fuzz/property test/scenario/browser-use) | 无 staging 自主测试 | staging 环境智能验证,发现集成问题 | P2 |
| 27 | AI Changelog | prd 部署时 Stage 6 读 `prev_semver_tag..HEAD` commit range,按 conventional-commit 类型分组,AI 生成用户向 changelog → `gh release create` | 无自动 changelog | 发布说明自动化,减少手工编写 | P2 |
| 28 | @Docubot | `pr-agent-docubot.yml` 监听 `issue_comment` 中 `@docubot` mention → AI 回答代码库问题 | 无代码库问答 | 降低新人上手门槛,减少重复问题 | P2 |
| 29 | Agent Review | `pr-agent-review.yml` 用 `RELEASE_PAT`(含 copilot scope)把 `@copilot` 加为 reviewer 自动 review | 无 AI 代码审查 | AI 辅助代码审查,发现人工容易遗漏的问题 | P2 |

#### 16.6.1 AI Agent 安全约束

所有 AI agent 遵循最小权限原则:

- **Agent 只读,Reporter 只写**:test-gen agent 写 finding 到 `triage/` 目录;reporter 独立 job 读 `triage/` 后用 `gh issue create` 入仓,reporter 没有 LLM 写权限
- **Gitleaks 扫描**:reporter 在开 issue 前用 gitleaks 扫描 triage 产物,防止 agent 泄漏 secret
- **LLM 从不持有 `issues:write`**:分离 agent(research)和 reporter(action)职责

---

## 十七、GitHub 原生模板与仓库约定(v1.5 新增)

GitHub 会在特定事件触发时自动加载指定路径的文件。本章定义 OpenCI 消费方仓库应具备的标准文件。

### 17.1 Issue Templates(YAML Form)

`.github/ISSUE_TEMPLATE/` 目录提供结构化模板,字段化 + 必填校验,后续 auto-label / AI triage 能直接读字段。

```yaml
# .github/ISSUE_TEMPLATE/config.yml
blank_issues_enabled: false   # 强制走模板,不允许空白 issue
contact_links:
  - name: Discussions
    url: https://github.com/org/repo/discussions
    about: 提问、讨论想法请用 Discussions
  - name: Security
    url: https://github.com/org/repo/security/advisories/new
    about: 安全漏洞请走私下渠道,不要公开 issue
```

模板文件:`bug-report.yml`、`feature-request.yml`、`question.yml`、`security-report.yml`(提示走私下渠道)。

### 17.2 PR Template

`.github/PULL_REQUEST_TEMPLATE.md` — 新建 PR 时自动填充描述。一个就够,不需要多个变体(GitHub 多 PR 模板的 query string 切换体验很差)。

```markdown
## 变更内容
<!-- 简述这个 PR 做了什么 -->

## 关联 Issue
Closes #

## 变更类型
- [ ] Bug fix
- [ ] New feature
- [ ] Breaking change
- [ ] Docs update
- [ ] Chore

## 测试方法
<!-- 如何验证这个 PR -->

## Checklist
- [ ] 已通过本地测试
- [ ] 已更新相关文档
- [ ] 已添加测试用例
```

### 17.3 CODEOWNERS

`.github/CODEOWNERS` 定义"谁负责哪部分代码",PR 涉及对应路径时自动请求 review,也是 issue auto-assign 的依据。

```
# Default
*                          @org/maintainers

# 前端
/frontend/                 @org/frontend-team
*.tsx                      @org/frontend-team

# 后端
/backend/                  @org/backend-team
/migrations/               @org/backend-team @org/dba

# AI 相关
/prompts/                  @org/ai-team
/agents/                   @org/ai-team

# 基础设施
/.github/                  @org/devops
/infrastructure/           @org/devops

# 安全敏感
/SECURITY.md               @org/security
```

### 17.4 Dependabot 配置

`.github/dependabot.yml` — 依赖自动更新。推荐 Renovate(支持 monorepo、自定义规则、SHA pinning),但 Dependabot 配置更简单。

```yaml
# .github/dependabot.yml
version: 2
updates:
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "weekly"
    labels:
      - "deps"
      - "security"
    # patch 自动合并
  - package-ecosystem: "npm"
    directory: "/"
    schedule:
      interval: "weekly"
    labels:
      - "deps"
  - package-ecosystem: "pip"
    directory: "/"
    schedule:
      interval: "weekly"
    labels:
      - "deps"
```

若用 Renovate,最小配置:

```json
{
  "extends": ["config:base", ":dependencyDashboard"],
  "packageRules": [
    {
      "matchManagers": ["github-actions"],
      "pinDigests": true,
      "labels": ["deps", "security"]
    },
    {
      "matchUpdateTypes": ["patch"],
      "automerge": true
    }
  ]
}
```

### 17.5 Labeler(按路径自动打 label)

`.github/labeler.yml` 配合 `actions/labeler` 自动按文件路径打 label:

```yaml
area:frontend:
  - frontend/**/*
  - "*.tsx"

area:backend:
  - backend/**/*

area:ai:
  - prompts/**/*
  - agents/**/*

area:docs:
  - docs/**/*
  - "*.md"

area:ci:
  - .github/**/*
  - actions/**/*
```

### 17.6 Auto Assign(PR 自动指定 reviewer)

`.github/auto-assign.yml` 配合 `kentaro/auto-assign-action`:

```yaml
addReviewers: true
addAssignees: author
reviewers:
  - alice
  - bob
numberOfReviewers: 1
```

### 17.7 Root 目录约定文件

不是 GitHub 强制的,但工具链和社区会去这些路径找:

| 文件 | 作用 | 必要性 |
| --- | --- | --- |
| `README.md` | 项目介绍 + 如何使用 | 必备 |
| `LICENSE` | 法律必备,缺这个等于"保留所有权利" | 必备 |
| `CHANGELOG.md` | 版本历史(release-drafter 自动生成) | 必备 |
| `.gitignore` | 排除不该入库的文件 | 必备 |
| `CONTRIBUTING.md` | 怎么贡献:fork → branch → PR 流程,代码规范 | 强烈推荐 |
| `CODE_OF_CONDUCT.md` | 行为准则,Contributor Covenant 是事实标准 | 强烈推荐 |
| `SECURITY.md` | 漏洞报告渠道,GitHub 会在 Security tab 自动展示 | 强烈推荐 |
| `GOVERNANCE.md` | 治理结构(多维护者时) | 成熟项目 |
| `MAINTAINERS.md` | 维护者列表 | 成熟项目 |
| `ROADMAP.md` | 路线图 | 成熟项目 |

**LICENSE 选择建议**:

- 想最大化采用率 → MIT 或 Apache 2.0
- 商业控制 → BSL(Sentry/MariaDB 用)或 AGPL
- 工具类/共享库 → Apache 2.0(对专利友好)

### 17.8 security.txt

`.well-known/security.txt` — 安全研究人员找漏洞报告渠道的标准文件,Web 项目应有:

```
Contact: mailto:security@example.com
Expires: 2027-01-01T00:00:00Z
Preferred-Languages: en, zh
Policy: https://example.com/security-policy
```

---

## 附录 A:实施优先级

Claude Code 按以下顺序实施,每阶段可独立验证:

| 优先级 | 实施内容 | 验证方式 |
|--------|---------|---------|
| P0 | `manifest.yml` + `_common/read-manifest` | 单元测试读取 SHA |
| P0 | `_common/detect-language` | 不同项目类型下验证输出 |
| P1 | `pr.yml` + 基础原子（lint/test/scan-deps） | 在示例仓库触发 PR |
| P1 | `claude-harness.yml` | 手动触发,验证 sticky comment |
| P2 | `ci.yml` + `build-docker` / `scan-image` / `sign-image` | 验证 digest 输出 |
| P2 | `stg.yml` + 部署链路 | 在测试 K8s 集群验证 |
| P3 | `prd.yml` + `pre-check`（version-align + observe-window） | 验证版本不对齐时正确失败 |
| P3 | `security-schedule.yml` + CodeQL + SBOM | 手动触发验证 Security tab |
| P4 | `community.yml` / `stale.yml` / `docs-*.yml` | 辅助功能,最后实施 |
| P5 | 十六章 Aicert 差距实施（按 P0/P1/P2 分批） | 参见 16.x 各子节验证方式 |
| P6 | `actions/integrations/notify-deploy` + Datadog/LangSmith/Axiom 原子 | stg/prd 部署后验证 marker 到达各平台 |
| P6 | `actions/observability/` 全套(query-*/collect-all/publish-report) | 手动触发 health-report.yml 验证 Issue + Slack |
| P6 | `.github/PULL_REQUEST_TEMPLATE.md` + `CODEOWNERS` + `labeler.yml` | 新建 PR 验证模板自动填充、reviewer 自动指定 |
| P6 | `.github/dependabot.yml` | 等 Dependabot PR 验证自动合并 |
| P6 | `CONTRIBUTING.md` / `CODE_OF_CONDUCT.md` / `SECURITY.md` / `.well-known/security.txt` | 检查 GitHub Security tab 展示 |

---

## 附录 B:禁止事项

以下行为被明确禁止,Claude Code 实施时须检查:

1. **任何 action 直接调用 Claude API**（必须经由 `claude-harness.yml`）
2. **第三方 action 使用版本 tag**（必须用 commit SHA）
3. **SHA 硬编码在 action 文件内**（必须从 `manifest.yml` 读取）
4. **Composite Action 调用另一个 Composite Action**（只能调用原子）
5. **工作流直接调用原子 Action**（必须经由 Composite）
6. **原子 Action 之间互相调用**
7. **`pull_request_target` 触发器 checkout PR head 代码后执行**（供应链安全风险）
8. **自实现 Docker 构建、secret 扫描、覆盖率上报等有成熟方案的功能**
9. **在 `stg.yml` 之前直接触发 `prd.yml`**（必须经过观察窗口）
10. **省略 `harden-runner` 步骤**（每个 job 必须加载）
11. **使用 `semgrep/semgrep-action`**（2020 年停更,改用 CLI: `pip install semgrep && semgrep ci`）
12. **使用 `amondnet/vercel-action`**（版本严重滞后,改用官方 Vercel CLI）
13. **`trufflehog` 引用 `@main`**（必须固定到发布版本 SHA,防止供应链攻击）
issue 缺少 type/area/priority 三标签即流转(必须先 triage)