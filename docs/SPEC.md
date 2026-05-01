# OpenCI 共享工作流库 — 设计规格文档

**版本**：v1.7
**用途**：可直接交给 Claude Code 实施的完整设计规格
**仓库定位**：公开 GitHub 仓库，供自己多个项目及外部项目通过 `uses:` 引用

---

## 变更日志

### v1.7(本版)— 一致性修复与实施盲点收口

**P0 修复(架构正确性)**

- 修复 `manifest.yml` 占位 SHA 与"安全默认"原则冲突:占位条目移到独立 `manifest-pending.yml`,主 manifest 只保留已验证 SHA;补全 `workflows:` 段(8 个之前漏列的工作流)
- 明确 `claude-harness` 双层调用判定规则:原子内部 → composite;独立 job(workflow_run/synthesize)→ reusable workflow
- 解决 PostHog/Sentry 双重定义:`prd.yml` 删除独立 `sentry-release` / `posthog-event` jobs,统一改为末尾调用 `notify-deploy` composite
- `prd.yml` 显式声明 `environment: production`,触发 GitHub 审批保护规则

**P1 一致性**

- 新增"job ≙ composite 一对一映射"规则,消除 job 与 composite 边界混淆
- 修复 15.2 消费方示例 `outputs` 语法错误(`needs.<job>.outputs` 而非顶层 `jobs.<>.outputs`)
- 新增 5.7 节"Concurrency 在 reusable workflow 中的语义"
- `detect-language` 增加 Gradle (`build.gradle` / `build.gradle.kts`) 和 Kotlin 检测;MegaLinter flavor 表同步
- CODEOWNERS 与 auto-assign-action 职责分工明确(CODEOWNERS 兜底,auto-assign 仅 round-robin)
- aicert 节折叠为单段引用,删掉与 7.8 节重复的表格
- dependabot vs renovate 二选一:推荐 Renovate,dependabot 配置移到附录作为备选

**P2 实施盲点**

- `observe-window` 给出明确迁移路径(`repository_dispatch` 延迟触发),标注为 P1 技术债
- 7.2 `check-error-rate` 展开 Sentry API endpoint、查询窗口、阈值判定的可执行细节
- 新增 8.5 节"消费方 Secrets 矩阵",统一列出全部可能的 secrets 与在哪些 workflow 必需/可选
- 18.2 act 测试明确不支持的场景清单,引导核心验证至 e2e
- 18.3 e2e 测试仓库补充 K8s 集群(kind)、kubeconfig、registry mock 的具体准备方式
- 附录 A 优先级表把 16 章的 P0 项(Concurrency / Secrets Preflight / graceful-skip / PR Templates / lefthook)从 P5 拆出,按本身优先级散到 P0–P3

**P3 收尾**

- 所有 `preflight:` 段补完整 `jobs:` 顶层结构,消除 yaml 误读
- `.well-known/security.txt` 归属说明:OpenCI 自身有一份 + 给消费方提供模板
- `vercel-action` 与 `semgrep-action` deprecated 块从 manifest.yml 移到附录 B
- 附录 D 新增 SHA 一致性验证脚本规则
- `manifest.yml` 补充 `actions/upload-pages-artifact` + `actions/deploy-pages`(docs-deploy.yml 需要)

**历史版本**(v1.0–v1.6)归档至 `docs/CHANGELOG-history.md`。

---

## 一、项目概述与设计原则

### 1.1 项目定位

本仓库是一个 GitHub Actions 共享库,提供三层可复用单元:

- **主工作流（Reusable Workflow）**：完整的阶段流水线，调用方一行引入  
  `uses: org/openCI/.github/workflows/pr.yml@v2`
- **Composite Action**：阶段内的组合逻辑，封装多个原子  
  `uses: org/openCI/actions/pr/lint-code@v2`
- **原子 Action**：最小职责单元，单一功能，明确输入输出  
  `uses: org/openCI/actions/pr/lint-node@v2`

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

主工作流调用 Composite,Composite 调用原子,原子不互相调用。AI 调用统一通过 claude-harness 入口,不直接调用 Claude API。

```
主工作流（Reusable Workflow）
  └── Composite Action（阶段级,job ≙ composite,一对一映射）
        └── 原子 Action（单一功能）
              └── （AI 原子专属）→ _common/claude-harness（composite,内联调用）

独立 AI Job 调用链(workflow_run / synthesize / 跨 workflow 聚合):
  主工作流 job → claude-harness.yml（reusable workflow,uses 引入）
                 └── 内部调用 _common/claude-harness composite
```

**Job ≙ Composite 一对一映射规则**:

主工作流的每个 job 名称应与其调用的 composite 名称一致(`lint` job → `lint-code` composite,`test` job → `test-unit` composite)。一个 job 只调一个 composite,不在 job 内串多个 composite。这样调用图就是 job 图,无需在两个层级间反复对照。

**claude-harness 双层调用判定规则**:

| 场景 | 用 composite (`_common/claude-harness`) | 用 reusable workflow (`claude-harness.yml`) |
| --- | --- | --- |
| 在原子 action 内部嵌入一次 AI 调用(如 `ai-triage` 取 priority) | ✓ | — |
| 主工作流的某个 job 完整就是一次 AI 任务(如 `health-report.synthesize`) | — | ✓ |
| AI 调用需要独立 job 级别的 timeout / permissions / secrets | — | ✓ |
| AI 调用嵌在某个原子的 step 序列中,与其他 step 共享 job context | ✓ | — |

判定原则:**AI 调用是 job 中的一个 step → composite;AI 调用是整个 job → reusable workflow**。

具体约束:

- 原子之间不互相调用
- Composite 不调用其他 Composite
- 主工作流不直接调用原子（必须经过 Composite,且 job ≙ composite）
- 一个 job 只调一个 composite,不串接
- AI 原子内的调用走 `_common/claude-harness` composite
- 独立 AI job 走 `claude-harness.yml` reusable workflow

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

#### 原则五：安全默认

供应链攻击是 GitHub Actions 生态的实质性威胁（tj-actions 2025/03、trivy-action 2026/03 相继被攻击）。设计上必须假定每个第三方 action 都可能被劫持。因此:

- **SHA 固定**:所有第三方 action 必须使用 commit SHA,不接受版本 tag
- **SHA 集中**:所有 SHA 维护在 `manifest.yml`,不在 action 内硬编码
- **权限最小化**:每个 job 显式声明 `permissions`,仅开放必要权限
- **harden-runner 必装**:每个工作流每个 job 第一步统一加载,审计出站连接
- **OIDC 优先**:认证使用 OIDC（id-token）,避免长期凭证

---

## 二、目录结构

仓库分四个顶层区域,按"变化频率"原则分离:

```
openCI/
├── .github/                              # 工作流 + GitHub 原生模板
│   ├── workflows/                        # 14 个主工作流(消费方 uses: 引用)
│   ├── ISSUE_TEMPLATE/                   # YAML form 模板
│   ├── PULL_REQUEST_TEMPLATE.md
│   ├── CODEOWNERS / labeler.yml / auto-assign.yml
│   └── renovate.json / dependabot.yml
│
├── actions/                              # action 实现,按阶段分目录
│   ├── _common/                          # detect-language / setup-env / post-comment
│   │                                     # / claude-harness(AI composite 入口)
│   ├── issue/    pr/    ci/    stg/    prd/    security/    community/
│   ├── integrations/                     # SaaS push: sentry / datadog / posthog /
│   │                                     # langsmith / axiom / slack / linear-link
│   │                                     # + notify-deploy composite
│   └── observability/                    # SaaS pull: query-* / collect-all /
│                                         # publish-report
│
├── prompts/                              # AI prompt(与 action 解耦,变化频率不同)
│   └── {stage}/{task}.md                 # pr/review、issue/triage、ci/smoke-eval、
│                                         # observability/daily-health-report
│
├── lib/                                  # 2+ action 共用脚本(wait-on.js / parse-sarif.sh)
│
├── manifest.yml                          # 第三方 SHA 注册表(已验证)
├── manifest-pending.yml                  # 待验证 SHA(不可被实际引用)
└── README / LICENSE(Apache-2.0)/ CHANGELOG / CONTRIBUTING /
    CODE_OF_CONDUCT / SECURITY / .well-known/security.txt
```

**主工作流清单**(`.github/workflows/`):`claude-harness` `issue` `issue-comment` `pr` `ci` `stg` `prd` `security-schedule` `docs-build` `docs-deploy` `release-docker` `stale` `community` `health-report`。

**actions/ 各阶段原子清单**:见 `manifest.yml` workflows 段(每个工作流的 inputs/outputs/secrets 定义),原子的实际职责在第五章及之后的章节描述。OpenCI 不在本规格冗余维护"目录到原子"的对照表,以仓库目录为准。

---

## 三、Action Manifest 注册表

`manifest.yml` 是全仓库的单一来源索引。所有 workflow / action 文件直接写 SHA(因为 GitHub Actions 不支持运行时读 SHA 给 `uses:`),`manifest.yml` 作为**校验源**:CI 在 PR 上跑一致性检查,确保仓库里所有 SHA 与 manifest 完全一致。

**关键约定**:

1. `deps:` 段只放**已验证 SHA**(SHA 经 `cosign verify-blob` 或在 GitHub 上人工对照过)。任何 `1234567890abcdef...` 占位条目必须放 `manifest-pending.yml`,不进主 manifest。
2. CI 检查 job(`verify-sha-consistency`)读 `manifest.yml` 与所有 workflow / action 文件,任何不一致 → check 失败。
3. 新增第三方 action → 先填 `manifest-pending.yml`,验证通过后人工迁移到 `manifest.yml`,同步替换文件中的 SHA。
4. **`deprecated:` 段已迁移到附录 B**(避免主配置文件夹带历史警示),仅保留运行时使用的活跃依赖。

```yaml
# manifest.yml(只放已验证 SHA)
version: "1.7"

# ─────────────────────────────────────────────────────────────────────────────
# 第三方依赖 SHA 注册表(仅已验证条目)
# 更新方式:Renovate Bot 自动提 PR + 人工 review,或手动 PR
# 校验:.github/workflows/verify-sha-consistency.yml(每个 PR 触发)
# ─────────────────────────────────────────────────────────────────────────────
deps:
  # ── GitHub 官方(全部已验证) ──────────────────────────────────────────
  actions/checkout:                    "11bd71901bbe5b1630ceea73d27597364c9af683"  # v4.2.2
  actions/setup-python:                "a26af69be951a213d495a4c3e4e4022e16d87065"  # v5.6.0
  actions/setup-go:                    "d35c59abb061a4a6fb18e82ac0862c26744d6ab5"  # v5.5.0
  actions/cache:                       "5a3ec84eff668545956fd18f4cc68c71c9f62eb4"  # v4.2.2
  actions/upload-artifact:             "ea165f8d65b6e75b540449e92b4886f43607fa02"  # v4.6.2
  actions/download-artifact:           "d3f86a106a0bac45b974a628896c90dbdf5c8093"  # v4.3.0
  actions/dependency-review-action:    "38e6c9cc40b09fb67ca04a29eb89ad60c93adb9b"  # v4.6.0
  actions/github-script:               "60a0d83039c74a4aee543508d2ffcb1c3799cdea"  # v7.0.1
  actions/labeler:                     "6570a1fa0235bf4a1e8a9f2f62d7e35e5cce0300"  # v5.0.0
  # docs-deploy.yml 需要
  actions/upload-pages-artifact:       "<待验证 SHA>"  # → manifest-pending.yml
  actions/deploy-pages:                "<待验证 SHA>"  # → manifest-pending.yml

  # ── Docker(全部已验证) ──────────────────────────────────────────────
  docker/setup-buildx-action:          "b5ca514318bd6ebac0fb2aedd5d36ec1b5c232a2"  # v3.10.0
  docker/login-action:                 "74a5d142397b4f367a81961eba4e8cd7edddf772"  # v3.4.0
  docker/metadata-action:              "902fa8ec7d6ecbf8d84d538b9b233a880e428804"  # v5.7.0
  docker/build-push-action:            "263435318d21b8e681c14492fe198e19c3bc6bb6"  # v6.18.0

  # ── AWS(全部已验证) ─────────────────────────────────────────────────
  aws-actions/configure-aws-credentials: "e3dd6a429d7300a6a4c196c26e071d42e0343502"  # v4.2.1

  # ── 安全(已验证) ────────────────────────────────────────────────────
  step-security/harden-runner:         "f808768d1510423e83855289c910610ca9b43176"  # v2.17.0
  sigstore/cosign-installer:           "59acb6260d9c0ba8f4a2f9d9b48431a222b68e20"  # v3.5.0
  github/codeql-action:                "23dab4bc6e7e24150d9e35e3b3260f29ea78e5c0"  # v3.28.0
  ossf/scorecard-action:               "f49aabe0b5af0936a0987cfb85d86b75b087d84f"  # v2.4.0

  # ── PR 质量(已验证) ─────────────────────────────────────────────────
  dorny/paths-filter:                  "de90cc6fb38fc0963ad72b210f1f284cd68cea1e"  # v3.0.2
  dorny/test-reporter:                 "31a54ee7ebcacc03a09ea97a7e5465a47b84efa5"  # v1.9.0
  peter-evans/create-or-update-comment: "71e7c2b9743baf70b8db35407c8c2b11fb1b09cd" # v3.0.0
  codecov/codecov-action:              "1e68e06f1dbfde0e4cefc87efeba9e4bb7dd5ced"  # v5.4.0

  # ── AI / Eval(已验证) ──────────────────────────────────────────────
  anthropics/claude-code-action:       "a4d5fe83c90d37e4f2fcbab2a0bf04e9c01e8ecf"  # v1.0.0
  promptfoo/promptfoo-action:          "8e12b04e93d24ea43d7694d8f27dd86e7abd5a72"  # v1.0.0

  # ── 发布(已验证) ────────────────────────────────────────────────────
  release-drafter/release-drafter:     "3f0f87098bd6b5c5b9a36d49c41d998ea58f9e0b"  # v6.1.0

  # ── 待验证条目 ──────────────────────────────────────────────────────
  # 以下条目当前 SHA 未经过本地验证,统一移至 manifest-pending.yml,
  # 验证完成(npm exec pin-github-action / 在 GitHub commits 页面对照)
  # 后再迁移到此 deps 段。详见 3.1 节。
  # → 见 manifest-pending.yml:
  #   - actions/setup-node
  #   - actions/stale (已归档,优先迁到 stale-org/stale)
  #   - pnpm/action-setup
  #   - astral-sh/setup-uv
  #   - aws-actions/amazon-ecs-deploy-task-definition
  #   - trufflesecurity/trufflehog
  #   - aquasecurity/trivy-action
  #   - amannn/action-semantic-pull-request
  #   - SonarSource/sonarcloud-github-action
  #   - oxsecurity/megalinter
  #   - appleboy/ssh-action
  #   - stale-org/stale
  #   - dessant/lock-threads
  #   - kentaro/auto-assign-action
  #   - slackapi/slack-github-action
  #   - getsentry/action-release
  #   - snyk/actions

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
      sonar-token: { required: false }
      snyk-token: { required: false }

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
      sentry-token: { required: false }
      datadog-api-key: { required: false }
      posthog-api-key: { required: false }
      slack-webhook-url: { required: false }

  - id: prd
    path: .github/workflows/prd.yml
    description: 生产发布（含 pre-check）
    inputs:
      image-digest: { type: string, required: true }
      stg-image-digest: { type: string, required: true }
      stg-deploy-time: { type: string, required: true }
      observation-minutes: { type: number, default: 30 }
      k8s-namespace: { type: string, default: "production" }
      run-migration: { type: boolean, default: false }
    secrets:
      kubeconfig-prd: { required: true }
      sentry-token: { required: false }
      datadog-api-key: { required: false }
      posthog-api-key: { required: false }
      slack-webhook-url: { required: false }

  - id: security-schedule
    path: .github/workflows/security-schedule.yml
    description: 每周全量安全扫描
    inputs:
      image-ref: { type: string, required: false }
    secrets:
      snyk-token: { required: false }

  # ── 完整工作流目录 ────────────────────────────────────────────────
  - id: issue
    path: .github/workflows/issue.yml
    description: Issue 生命周期管理(auto-label / ai-triage / detect-duplicates)
    secrets:
      anthropic-api-key: { required: false }

  - id: issue-comment
    path: .github/workflows/issue-comment.yml
    description: Issue 评论 slash command 处理
    secrets: {}

  - id: community
    path: .github/workflows/community.yml
    description: 新贡献者欢迎 + PR/Issue 联动检查
    secrets: {}

  - id: stale
    path: .github/workflows/stale.yml
    description: 过期 Issue/PR 自动标记与关闭
    inputs:
      issue-stale-days: { type: number, default: 60 }
      issue-close-days: { type: number, default: 14 }
      pr-stale-days: { type: number, default: 30 }
      pr-close-days: { type: number, default: 7 }
    secrets: {}

  - id: docs-build
    path: .github/workflows/docs-build.yml
    description: PR 时文档构建验证(链接检查)
    secrets: {}

  - id: docs-deploy
    path: .github/workflows/docs-deploy.yml
    description: main push 文档部署到 GitHub Pages
    secrets: {}

  - id: release-docker
    path: .github/workflows/release-docker.yml
    description: Tag 触发 Docker 镜像发布与签名
    secrets: {}

  - id: health-report
    path: .github/workflows/health-report.yml
    description: 定时健康日报(collect → synthesize → publish)
    secrets:
      anthropic-api-key: { required: true }
      sentry-token: { required: false }
      datadog-api-key: { required: false }
      posthog-api-key: { required: false }
      langsmith-api-key: { required: false }
      axiom-token: { required: false }
      slack-webhook-url: { required: false }
```

### 3.1 manifest-pending.yml 与验证流程

`manifest-pending.yml` 与 `manifest.yml` 同结构,但只放**未经验证 SHA**(占位符或 Renovate Bot 刚提的 PR 中的 SHA)。

**SHA 验证 checklist**(完成全部才能迁移到主 manifest):

1. 在 GitHub 上访问 action 仓库的 `commits/<tag>` 页面,确认 SHA 与 tag 关联无误
2. 用 `npx pin-github-action` 在测试 workflow 上 pin 一次,对照输出 SHA
3. 高敏感 action(harden-runner / cosign / trivy)额外 `cosign verify-blob` 校验 release artifact 签名
4. 验证通过 → PR 把条目从 `manifest-pending.yml` 剪切到 `manifest.yml`,同步替换 workflow / action 文件中的 `<待验证 SHA>` 占位符

**已淘汰 action(禁止使用)**:见附录 B。

---

## 四、语言检测单一来源

**文件**:`actions/_common/detect-language/action.yml`

**职责**:根据仓库根目录文件探测语言栈,输出标准化语言标识符。所有需要语言信息的工作流均通过此 action 获取,不允许各工作流自行实现检测逻辑。

**输入**:无（读取 `github.workspace` 文件系统）

**输出**:

```yaml
outputs:
  language:           # node | python | go | java | kotlin | unknown
  package-manager:    # npm | pnpm | yarn | uv | pip | go-mod | maven | gradle | gradle-kts | unknown
  version-file:       # .nvmrc | .python-version | go.mod | pom.xml | build.gradle | ""
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

4. JVM 项目检测(Java / Kotlin 共享构建工具):
   ├── pom.xml 存在                 → language=java,   package-manager=maven
   ├── build.gradle.kts 存在        → language=kotlin, package-manager=gradle-kts
   │      └── 若同时存在 *.java 但无 *.kt 文件 → language=java, package-manager=gradle-kts
   ├── build.gradle 存在            → language=java,   package-manager=gradle
   │      └── 若同时存在 *.kt 文件   → language=kotlin, package-manager=gradle
   version-file: pom.xml | build.gradle | build.gradle.kts

5. 全部未匹配 → language=unknown
```

**Kotlin 判定**:Gradle 项目同时支持 Java 和 Kotlin,通过源文件后缀(`*.kt` vs `*.java`)区分主语言。混合项目以 Kotlin 优先(因为 Kotlin 工具链可处理 Java 文件,反之不成立)。

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
2. 若为空,从 `openCI/prompts/{task}.md` 加载内置 prompt

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

**Concurrency**:
```yaml
concurrency:
  group: claude-harness-${{ github.run_id }}
  cancel-in-progress: false
```

**Secrets Preflight**(写在 `jobs:` 段下作为首个 job,所有其他 job 通过 `needs: preflight` 等待它):

```yaml
jobs:
  preflight:
    runs-on: ubuntu-latest
    timeout-minutes: 2
    steps:
      - name: Check required secrets
        run: |
          bash .github/scripts/preflight-secrets.sh \
            --required "ANTHROPIC_API_KEY" \
            --optional ""

  ai-review:
    needs: preflight
    timeout-minutes: 15
    # ...
```

> 后续章节用 `Preflight required: X / optional: Y` 简写代替完整 yaml,实际实现都遵循上面这个 `jobs.preflight` 结构。

### 5.2 pr.yml

**触发**:`workflow_call`

**Inputs**:
```yaml
inputs:
  language: { type: string, default: "" }
  enable-ai-review: { type: boolean, default: true }
  enable-eval: { type: boolean, default: false }
  coverage-threshold: { type: number, default: 80 }
  pr-review-prompt-path: { type: string, default: "" }
  # pr-review-prompt-path 映射到 claude-harness 的 prompt-path 输入
  # pr.yml 内部调用 claude-harness.yml 时传递:
  #   prompt-path: ${{ inputs.pr-review-prompt-path }}
```

**Jobs**(每 job 首步 `harden-runner`,所有 job `needs: preflight`):

| Job | needs | 阻断? | 实现 |
| --- | --- | --- | --- |
| `detect-language` | preflight | 阻断 | `_common/detect-language`(if `inputs.language == ''`) |
| `lint` | detect-language | 阻断 | `oxsecurity/megalinter`,flavor 由 detect-language 路由(详见十一章) |
| `test` | detect-language | 阻断 | `test-unit` composite + `dorny/test-reporter` + upload coverage artifact |
| `coverage` | test | 非阻断 | `check-coverage` → codecov-action |
| `scan-deps` | preflight | 阻断 | `actions/dependency-review-action` |
| `scan-secrets` | preflight | 非阻断 | TruffleHog(固定 SHA,禁止 @main) |
| `scan-sonarcloud` | preflight | 非阻断 | SonarCloud(graceful-skip) |
| `validate-pr-title` | preflight | 阻断 | `amannn/action-semantic-pull-request` |
| `validate-pr-desc` | preflight | 阻断 | 检查 `Closes #N` / `Fixes #N` 或 `no-issue` label |
| `build-check` | detect-language | 阻断 | `docker build --load`(仅验证,不推送) |
| `ai-review` | lint, test | 非阻断 | `review-ai` → `_common/claude-harness`(task=pr-review) |
| `eval-prompt` | ai-review | 非阻断 | promptfoo-action(`if: always() && enable-eval && paths.prompts changed`) |

**配置**:
- **权限**:`contents:read` / `pull-requests:write` / `security-events:write` / `id-token:write`
- **Concurrency**:`pr-${{ github.event.pull_request.number }}`,`cancel-in-progress: true`
- **Preflight required**:`CODECOV_TOKEN`(私仓);**optional**:`ANTHROPIC_API_KEY` / `SONAR_TOKEN` / `SNYK_TOKEN` / `SLACK_WEBHOOK_URL`
- **Timeouts**(分钟):preflight=2 / detect-language=2 / lint=10 / test=15 / coverage=5 / scan-{deps,secrets}=5 / scan-sonarcloud=10 / validate-pr-{title,desc}=2 / build-check=15 / ai-review=15 / eval-prompt=10

### 5.3 ci.yml

**Jobs**:`detect-language` → `build-docker`(outputs: `image-digest`, `image-size`)→ 并行 `scan-image`(Trivy → SARIF)/ `sign-image`(Cosign OIDC)/ `check-migration`(if `run-migration`)/ `eval-smoke`(if `enable-ai-smoke`,经 claude-harness task=smoke-eval)。

**Image 命名**:`ghcr.io/{owner}/{image}:main`(latest)+ `:sha-{git-sha}`(精确)。

**Workflow outputs**(reusable workflow 顶层):`image-digest` = `jobs.build-docker.outputs.digest`,`deploy-time` = `jobs.build-docker.outputs.completed-at`。

### 5.4 stg.yml

**触发**:`workflow_call` + `workflow_dispatch`(允许手动)。

**Jobs**(串行,失败即停):`preflight` → `deploy-k8s` → `run-migration`(if `run-migration`)→ `smoke-test` → `notify-deployed`。

**deploy-k8s 实现**:`kubectl set image` + `kubectl rollout status --timeout=300s`,镜像引用 `ghcr.io/{owner}/{image}@${IMAGE_DIGEST}`(by digest,非 tag)。

**配置**:
- **Outputs**:`deploy-time`(value: `${{ steps.deploy.outputs.completed-at }}`,传给 `prd.yml` 的 `stg-deploy-time`)
- **Concurrency**:`deploy-stg-${{ github.ref }}`,`cancel-in-progress: false`
- **Preflight required**:`KUBECONFIG_STG`;**optional**:`SENTRY_TOKEN` / `DATADOG_API_KEY` / `POSTHOG_API_KEY` / `SLACK_WEBHOOK_URL`
- **Timeouts**(分钟):preflight=2 / deploy-k8s=10 / run-migration=10 / smoke-test=10 / notify-deployed=5

### 5.5 prd.yml

**触发**:
```yaml
on:
  workflow_call:
  workflow_dispatch:    # 允许手动触发部署
  push:
    tags:
      - "v*"           # Tag 触发发布
```

**Inputs**:
```yaml
inputs:
  image-digest: { type: string, required: true }
  stg-image-digest: { type: string, required: true }
  stg-deploy-time: { type: string, required: true }
  observation-minutes: { type: number, default: 30 }
  k8s-namespace: { type: string, default: "production" }
  run-migration: { type: boolean, default: false }
  # 可观测性服务开关(透传给 notify-deploy composite)
  enable-sentry: { type: boolean, default: true }
  enable-datadog: { type: boolean, default: false }
  enable-posthog: { type: boolean, default: true }
  enable-langsmith: { type: boolean, default: false }
  enable-axiom: { type: boolean, default: false }
```

**配置**:
- **Concurrency**:`deploy-prd-${{ github.ref }}`,`cancel-in-progress: false`
- **Preflight required**:`KUBECONFIG_PRD`;**optional**:`SENTRY_TOKEN` / `DATADOG_API_KEY` / `POSTHOG_API_KEY` / `SLACK_WEBHOOK_URL`
- **Timeouts**(分钟):preflight=2 / pre-check=45(含观察窗口)/ deploy-k8s=10 / run-migration=10 / smoke-test=10 / create-release=5 / notify-deployed=5 / notify-observability=5

**Environment 审批**:`deploy-k8s` 与 `run-migration` job 显式声明 `environment: production`,触发 GitHub Environment 配置的审批保护规则与 secret 隔离:

```yaml
jobs:
  deploy-k8s:
    needs: pre-check
    environment: { name: production, url: https://app.example.com }
  run-migration:
    needs: deploy-k8s
    environment: production
```

**Job 顺序**:

```
pre-check(version-align + observe-window + check-error-rate)
   → [environment: production 审批]
   → deploy-k8s → run-migration → smoke-test → create-release → notify-deployed
   → notify-observability(调用 notify-deploy composite,继 continue-on-error)
```

`notify-observability` 是单 step job:`needs: notify-deployed`,`if: always() && needs.deploy-k8s.result == 'success'`,**不带** `environment: production`(事件推送无需审批),`continue-on-error: true`,调用 `./actions/integrations/notify-deploy` 并透传所有 `enable-*` 开关与 secrets。

**关键设计点**:

- **check-error-rate**:观察窗口内通过 Sentry API 检查 STG 错误率,异常则阻断 PRD 部署(详见 7.2 节)
- **可观测性事件推送统一收口**:Sentry release / PostHog deploy event / Datadog deployment event / LangSmith tag / Axiom log 全部由 `notify-deploy` composite 在 `notify-observability` job 一次性扇出。

**回滚策略**:smoke-test 失败时 `kubectl rollout undo` 回滚到上一稳定版,并自动创建 P1 incident issue(label `incident,priority:p1`)。

#### pre-check Composite

两个串行子步骤,均在 `actions/prd/` 目录下:

- **verify-version-align**:比对 `inputs.image-digest` 与 `inputs.stg-image-digest`,不一致 → `::error title=Version Mismatch` + exit 1。防止"测的和上的不一致"。
- **observe-window**:计算 `inputs.stg-deploy-time` 距今 elapsed 分钟数,< `observation-minutes` 则 `sleep` 至窗口结束。emit `::notice title=Observation Window::elapsed=X required=Y`。

**已知技术债(P1)**:

当前 `observe-window` 用 `sleep $WAIT` 阻塞 runner,30 分钟观察期 × 每月 ~30 次部署 = 每月 ~15 小时 runner 时间浪费。**P1 迁移方案**:

```
方案 A:repository_dispatch 延迟触发(推荐)
─────────────────────────────────────
1. stg.yml 部署成功后,记录 stg-deploy-time 到 GitHub Variable 或 Issue
2. stg.yml 末尾调度一个 GitHub-hosted scheduler(如 GitHub Scheduled Workflows
   或外部 cron):在 stg-deploy-time + observation-minutes 时刻
   发送 repository_dispatch event
3. prd.yml 改为 on: repository_dispatch: types: [observe-window-complete]
4. observe-window action 退化为纯校验:验证 elapsed >= required,不再 sleep

方案 B:workflow_run 链式触发
─────────────────────────────────────
1. 引入中间 workflow observe-gate.yml,on: workflow_dispatch with delay
2. stg.yml 完成 → workflow_run 触发 observe-gate.yml
3. observe-gate.yml 内部 sleep 后 dispatch prd.yml
   (问题:仍占用 runner,只是 runner 类型从 prd 转移到 gate,未根除)

结论:采用方案 A,作为 P1 技术债跟进。
```

**临时缓解**:`pre-check` job 的 `timeout-minutes: 45` 已含观察窗口预算,且 `concurrency.cancel-in-progress: false` 避免 runner 浪费在被取消的 run 上。

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

**配置**:
- **Concurrency**:`security-schedule`(全局单例),`cancel-in-progress: false`
- **Preflight required**:无;**optional**:`SNYK_TOKEN` / `GITLEAKS_LICENSE`
- **Timeouts**(分钟):preflight=2 / codeql-scan=30 / scan-image=15 / scan-snyk=15 / generate-sbom=10 / scorecard=15

**Job 并行**:`codeql-scan` / `scan-image`(if image-ref) / `generate-sbom` / `scorecard`,全部 upload SARIF/artifact 到 GitHub Security tab 或 OpenSSF。

### 5.7 Concurrency 在 Reusable Workflow 中的语义

OpenCI 所有主工作流都是 reusable workflow(`on: workflow_call`),内部使用的 `${{ github.* }}` 表达式遵循 GitHub Actions 的"调用方上下文"规则,理解这点是写对 concurrency group 的前提。

**关键事实**:

| 表达式 | 在 reusable workflow 内部的值 |
| --- | --- |
| `github.ref` | **调用方**的 ref(如 `refs/heads/main`、`refs/pull/42/merge`) |
| `github.sha` | **调用方**的 sha |
| `github.event_name` | **调用方**的事件类型(`pull_request` / `push` / `workflow_dispatch`) |
| `github.repository` | **调用方**的仓库(不是 OpenCI 仓库) |
| `github.run_id` | 当前(被调用)workflow 的 run id,每次调用唯一 |
| `inputs.<x>` | `with:` 传入的值 |

**Concurrency 设计模式**:

```yaml
# pr.yml — 同一 PR 多次 push,取消旧 run
concurrency:
  group: pr-${{ github.event.pull_request.number }}
  cancel-in-progress: true

# ci.yml / stg.yml / prd.yml — 同 ref 串行,不取消
concurrency:
  group: ci-${{ github.ref }}        # 调用方 ref → 通常 main / release branch
  cancel-in-progress: false

# claude-harness.yml — 每次调用独立(github.run_id 唯一)
concurrency:
  group: claude-harness-${{ github.run_id }}
  cancel-in-progress: false

# health-report.yml — 全局单例(防止 cron 与手动重叠)
concurrency:
  group: health-report
  cancel-in-progress: false
```

**常见误区**:

- ❌ `group: ${{ github.workflow }}-${{ github.ref }}` — `github.workflow` 在 reusable workflow 内是被调用方名字,不是调用方,会让所有调用方共享同一个 group,意外串行
- ❌ `group: openCI-pr-${{ github.event.pull_request.number }}` — 多个消费方仓库都用 OpenCI,group 名加常量 `openCI-` 没意义(不同仓库的 group namespace 已经天然隔离)
- ✓ `group: pr-${{ github.event.pull_request.number }}` — 简单的、依赖调用方 PR number 的 group 名

**调用方的 concurrency**:消费方在自己的顶层 workflow 里也可以声明 concurrency,与 reusable workflow 内部的 concurrency 互不冲突——两层都可以独立触发取消。一般建议消费方顶层不设,把 concurrency 控制权交给 OpenCI。

---

## 六、Issue 管理体系

Issue 是产品反馈、bug 报告、功能讨论的入口。一个成熟项目的 issue 管理需要:模板规范 + 自动分类 + 生命周期管理 + 与 PR 的双向联动。

### 6.1 Issue Templates(YAML Form)

OpenCI 在 `.github/ISSUE_TEMPLATE/` 提供 YAML form 模板范例(`bug-report.yml` / `feature-request.yml` / `question.yml` / `security-report.yml`)。YAML form 的结构化字段(必填 + 下拉)直接产出可机读数据,被后续 `auto-label` 与 `ai-triage` 消费。

**bug-report 关键字段**:`version`(input,必填) / `area`(dropdown:frontend/backend/infra/db/ai/docs,必填) / `reproduction` 复现步骤(textarea,必填) / `expected` 期望行为(textarea,必填) / `severity`(dropdown:阻塞/严重/一般/轻微,必填)。模板顶部 `labels: ["type:bug", "status:needs-triage"]` 自动打初始 label。

### 6.2 issue.yml 工作流

**触发**:`issues: types: [opened]`。

**Jobs**(`validate-form` 通过后并行触发后续):

| Job | 行为 |
| --- | --- |
| `validate-form` | 检查 form 必填字段;不通过 → 评论提示 + 关闭 |
| `auto-label` | 按 form 字段映射 `area:*` / `severity:*` label |
| `detect-duplicates` | `gh issue list --search "<title 关键词>"` 找相似;found → 评论 + 打 `possible-duplicate` |
| `ai-triage` | 调用 `_common/claude-harness`(task=issue-triage),AI 返回 JSON `{priority, reasoning, suggested_assignee, is_security}`,据此打 `priority:*` / `security` label |
| `welcome-contributor` | `if: FIRST_TIME_CONTRIBUTOR`,评论欢迎 + 贡献指南 |
| `auto-assign` | 按 CODEOWNERS + `area:*` label 设 assignee |

**ai-triage 安全要点**:context 必须用 `jq -n --arg` 构造 JSON,**禁止**直接拼字符串(防 prompt injection)。AI 输出固定 JSON schema,由 shell 用 `jq -r` 解析后调 `gh issue edit --add-label`。安全相关 issue 自动加 `security` + `private-discuss` label,触发独立流程。

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

**权限判定**:`github.event.comment.author_association` ∈ `{OWNER, MEMBER, COLLABORATOR}` 视为授权;`/help` 任何人可用。

**实现**:`actions/issue/parse-command` 解析命令名 + args + authorized flag → `actions/issue/execute-command` 按命令分支(`/assign` → `gh issue edit --add-assignee`、`/label` → `--add-label`、`/close` → `gh issue close` 等)。

### 6.4 community.yml(社区互动)

**触发**:`pull_request: [opened]` + `issues: [opened]` + `issue_comment: [created]`(后者带 `if: contains(github.event.comment.body, '/')` 过滤,减少无效 run)。

**职责**(跨 issue/PR 统一处理):新贡献者欢迎(评论 + 贡献指南链接)/ 可选 CLA 检查 / PR 描述 `Closes #N` 语法校验 / merge conflict 出现时评论提醒作者 rebase。

### 6.5 stale.yml(过期清理)

`schedule: cron: '0 2 * * *'`,使用 `stale-org/stale`(原 `actions/stale` 已归档)。**Inputs**:`issue-stale-days`(60)/ `issue-close-days`(14)/ `pr-stale-days`(30)/ `pr-close-days`(7)。豁免 label:`pinned,security,help-wanted,priority:p0,priority:p1`(issue),`pinned,security,wip`(PR)。

后接 `lock-resolved` job(`dessant/lock-threads`),关闭 30 天后锁定 issue/PR 评论。

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

### 6.7 PR ↔ Issue 联动

PR 描述里的 `Closes #N` / `Fixes #N` / `Resolves #N` 是流程的关键节点:

- merge 后 GitHub 自动关闭关联 issue
- release-drafter 把 issue 标题 + reporter 写入 changelog
- 项目板自动把 issue 卡片移到 Done

`actions/pr/validate-pr-description/action.yml`:检查 PR 描述必须满足以下之一:

- 包含 `Closes #N` / `Fixes #N` / `Resolves #N`
- 或 PR 标记了 `no-issue` label(明确说明无关联 issue,如纯 chore)

不满足则 PR check 失败,阻断合并。

---

## 七、外部服务集成

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

**集成点**:**不再作为独立 jobs**,统一通过 7.8.1 节的 `notify-deploy` composite 在 stg/prd 末尾的 `notify-observability` job 中按 `enable-sentry` 开关启用。原 stg.yml 的 `notify-deployed` job 仅负责 Slack 通知,Sentry release 已由 `notify-observability` 接管。

**角色二:观察窗口质量门**

`observe-window` 不应该仅仅 sleep,真正有价值的是观察期内的错误率。`check-error-rate` 通过 Sentry API 查询 STG 环境错误率,异常则阻断 PRD 部署。

`actions/prd/check-error-rate/action.yml`:

**Inputs**:`sentry-token`(必需) / `sentry-org` / `sentry-project` / `environment`(默认 `staging`) / `window-minutes`(默认 30) / `baseline-error-rate`(默认 `0.005`) / `threshold-multiplier`(默认 `2.0`) / `min-events`(默认 100)。
**Outputs**:`error-rate` / `total-events` / `passed`。

**实现**:两步 composite。

1. **Query Sentry Stats v2 API** — 查询 [Sentry Stats v2](https://docs.sentry.io/api/organizations/retrieve-event-counts-for-an-organization-v2/) 端点 `GET /api/0/organizations/{org}/stats_v2/`,query string `field=sum(quantity)&groupBy=outcome&project={proj}&environment={env}&start={ts}&end={ts}&interval=1m`,Auth `Bearer $SENTRY_TOKEN`。第一次查 `category` 不限取 TOTAL,第二次加 `category=error` 取 ERRORS。`jq` filter 只取 `outcome == "accepted"` 的 `sum(quantity)` 求和。`RATE = ERRORS / TOTAL`(scale=6,bc 算)。
2. **Evaluate threshold** — `THRESHOLD = baseline × multiplier`;若 `TOTAL < min-events` → skip 判定(`::notice` + `passed=true`);若 `RATE > THRESHOLD` → `::error title=Error Rate Exceeded` + `exit 1`;否则 `::notice title=Error Rate OK ✓`。

**判定逻辑**:

1. **数据量门槛**:窗口内事件数 < `min-events`(默认 100)→ 跳过判定(数据不足以做统计判断)
2. **基线倍数法**:实际错误率 > `baseline-error-rate × threshold-multiplier`(默认 0.5% × 2 = 1%)→ 阻断
3. **基线来源**:消费方应根据自己历史 7 天 STG 错误率均值校准 `baseline-error-rate`,而不是用默认值

**调优建议**:

- 新项目前 2 周错误率波动大,建议 `min-events: 1000` + `threshold-multiplier: 5.0` 宽松运行,稳定后收紧
- 高流量项目(>10k events / 30min)可降到 `threshold-multiplier: 1.5`,更快捕捉异常
- 检查 prompt 期间 `--dry-run` 模式跑一周,记录误判与漏判,再决定是否阻断生产

### 7.3 SonarCloud 集成

`actions/pr/scan-sonarcloud/action.yml` — graceful-skip 模式:`SONAR_TOKEN` 缺失则 skip(注 annotation),否则用 `SonarSource/sonarcloud-github-action` 跑分析。

**Inputs**:`sonar-organization`(必需) / `sonar-project-key`(必需) / `sonar-host-url`(默认 `https://sonarcloud.io`) / `sonar-token`(可选)。

**与 Codecov 的分工**:Codecov 管覆盖率,SonarCloud 管 code smell + 漏洞 + quality gate。两者均对开源仓库免费,通常并行启用。

### 7.4 PostHog 集成(AI 项目推荐)

`actions/integrations/posthog-event/action.yml` — `curl POST https://app.posthog.com/capture/` 发自定义事件。**Inputs**:`api-key` / `event`(deploy / release / hotfix) / `environment` / `version` / `properties`(可选 JSON)。Body 用 `jq -n --arg` 构造避免注入。

**集成点**:不作独立 job,由 `notify-deploy` composite(7.8.1)按 `enable-posthog` 开关在 `notify-observability` job 中调用。**效果**:PostHog 时间线打 deployment 标记,后续将用户行为变化与部署时间点关联分析。

### 7.5 Slack 通知集成

`actions/integrations/slack-notify/action.yml` 包装 `slackapi/slack-github-action`,Block Kit payload(header / section / context with run link)。**Inputs**:`webhook-url` / `status`(success/failure/warning) / `title` / `message` / `context`(可选)。

**触发策略**(按需,避免噪音):pr.yml 失败 → 不通知(开发者自己看);ci.yml 失败 → `#ci-alerts`;stg 完成 → `#deploys`;prd 完成 → `#releases` + `#engineering`;security-schedule 高危 CVE → `#security`。

### 7.6 Snyk 集成(可选)

`actions/pr/scan-snyk/action.yml` — graceful-skip 模式;`SNYK_TOKEN` 缺失则 skip,否则跑 `snyk/actions/<language>@<SHA>`。**Inputs**:`language`(node/python/java/go) / `severity`(默认 high) / `snyk-token`(可选)。

**定位**:开源项目用 dependency-review + Trivy 已足够;商业项目加 Snyk 获更好的漏洞数据库与修复建议。

### 7.7 Linear 集成

GitHub 与 Linear 双向同步走官方 Linear GitHub App,OpenCI 不重造。仅 `community.yml` 调用 `actions/integrations/linear-link/` 检查 PR 描述/分支名是否含 LIN-XXX 编号,缺失则评论提醒。

### 7.8 可观测性双模式架构

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

`actions/integrations/notify-deploy/action.yml`(Composite,扇出到 5 个原子)。

**Inputs**:`environment` / `version` / `git-sha`(均必需)+ 5 个 `enable-{sentry,datadog,posthog,langsmith,axiom}` boolean 开关 + 5 个对应 token(可选)。Secrets 必须通过 `with:` 传入(composite 无法访问 workflow-level secrets)。

**实现**:5 个 step,每个 `if: inputs.enable-X == 'true'` + `continue-on-error: true` + `uses: ./actions/integrations/{service}` + 透传 metadata。

**关键设计点**:

- `continue-on-error: true`:推送失败绝不阻断部署。Sentry 挂了不能让你回滚 prd。
- 每个原子内部 `timeout 30s` + 失败静默:单服务故障不影响其他服务。
- fan-out 在 composite 而非 workflow:符合"workflow → composite → atom"层级。
- 共用 metadata(`environment` / `version` / `git-sha`)在 composite 层统一接收一次,不在每个原子重复声明。

**调用方式**:见 5.5 prd.yml 的 `notify-observability` job。

#### 7.8.2 Pull 模式:Health Report(Collect → Synthesize → Publish)

定时从外部服务拉数据 + Claude 合成日报,三步走:

`.github/workflows/health-report.yml`:

**触发**:`schedule: cron: '0 1 * * 1-5'`(工作日北京 09:00)+ `workflow_dispatch`。

**Jobs**(4 阶段):

| Job | needs | 实现 |
| --- | --- | --- |
| `collect` | — | matrix `[sentry, datadog, posthog, langsmith, axiom]`,`fail-fast: false`,每个 `query-*` 原子返回固定 schema JSON;失败时返回 `{"_error": "...", "_partial": true}` 让 Claude 在缺数据时也能继续 |
| `merge` | collect | `jq -n --argjson` 合并 5 个 service output 为单个 JSON,写入 step output |
| `synthesize` | merge | 调用 `claude-harness.yml` reusable workflow(task=daily-health-report,prompt-path=`prompts/observability/daily-health-report.md`,context=merged JSON)|
| `publish` | synthesize | `actions/observability/publish-report` 同时发 GitHub Issue + Slack `#daily-health` |

**每个服务拉什么数据(初始建议)**:

| 服务 | 拉取内容 |
|------|---------|
| Sentry | 过去 24h 错误总数 / Top 5 错误类型 / 错误率趋势 |
| Datadog | p50/p95/p99 延迟 / 错误率 / 关键 metric 异常 |
| PostHog | DAU / 关键漏斗转化率 / 异常事件 |
| LangSmith | LLM 调用量 / 总成本 USD / token 用量 / Top 失败 prompt |
| Axiom | 错误日志条数 / Top error pattern |

**Claude 输出结构**:固定 markdown 模板(TL;DR / 需要关注 / 关键指标 / LLM 用量与成本 / 建议行动项),便于 issue 标题摘录与 Slack 卡片渲染。完整模板见 `prompts/observability/daily-health-report.md`。

---

## 八、可观测性 Annotation 规范与消费方 Secrets 矩阵

### 8.1 Annotation 规范

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
| 错误率检查 | notice/error | `::notice title=Error Rate OK::rate=$R threshold=$T events=$N ✓` |
| CVE 发现 | warning | `::warning title=CVE Found::$ID severity=$SEV package=$PKG` |
| 部署完成 | notice | `::notice title=Deployed::env=$ENV digest=$D time=$T` |
| 测试失败 | error | `::error file=$FILE,line=$LINE::Test failed: $MSG` |

### 8.2 消费方 Secrets 矩阵

下表统一列出消费方接入 OpenCI 时**所有可能用到**的 secrets,按 workflow 标注必需(✓)/可选(○)/不使用(—)。`preflight-secrets.sh` 在 workflow 启动时检查,缺失必需 secret 立即 fail。

| Secret | claude-harness | pr.yml | ci.yml | stg.yml | prd.yml | security-schedule | health-report |
| --- | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| `ANTHROPIC_API_KEY` | ✓ | ○ | ○ | — | — | — | ✓ |
| `GITHUB_TOKEN` *(自动)* | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `REGISTRY_TOKEN` | — | — | ✓ | — | — | — | — |
| `KUBECONFIG_STG` | — | — | — | ✓ | — | — | — |
| `KUBECONFIG_PRD` | — | — | — | — | ✓ | — | — |
| `CODECOV_TOKEN` | — | ✓(私仓必需) | — | — | — | — | — |
| `SONAR_TOKEN` | — | ○ | — | — | — | — | — |
| `SNYK_TOKEN` | — | ○ | — | — | — | ○ | — |
| `SENTRY_TOKEN` | — | — | ○ | ○ | ✓(check-error-rate) | — | ○ |
| `SENTRY_ORG`, `SENTRY_PROJECT` | — | — | ○ | ○ | ✓ | — | ○ |
| `DATADOG_API_KEY` | — | — | — | ○ | ○ | — | ○ |
| `POSTHOG_API_KEY` | — | — | ○ | ○ | ○ | — | ○ |
| `LANGSMITH_API_KEY` | — | — | — | ○ | ○ | — | ○ |
| `AXIOM_TOKEN` | — | — | — | ○ | ○ | — | ○ |
| `SLACK_WEBHOOK_URL` | — | — | ○ | ○ | ○ | ○ | ○ |
| `GITGUARDIAN_API_KEY` | — | ○ | — | — | — | ○ | — |
| `GITLEAKS_LICENSE` | — | — | — | — | — | ○ | — |
| `LINEAR_API_KEY` | — | ○(community) | — | — | — | — | — |

**图例**:✓ 必需(缺失即 fail) / ○ 可选(graceful-skip 自动跳过) / — 不使用。`GITHUB_TOKEN` 由 GitHub 自动注入。

---

## 九、安全规范

### 9.1 SHA 固定操作

**原则**:所有 action 文件中的第三方 `uses:` 必须使用完整 40 位 commit SHA,不接受版本 tag。

**实现方式**:Action 文件中直接写 SHA,`manifest.yml` 作为验证源（非运行时源）。CI 检查 job 确保所有 action 文件的 SHA 与 manifest 一致。

**Action 文件直接写 SHA**:

```yaml
steps:
  - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683  # v4.2.2
    with:
      fetch-depth: 0
```

**SHA 一致性验证**（CI job,每个 PR 触发）:

```yaml
verify-sha-consistency:
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@{SHA}
    - name: Verify all action SHAs match manifest
      run: |
        # 提取所有 workflow/action 文件中的第三方 uses: SHA
        # 与 manifest.yml 中的 SHA 比对
        # 不一致则 check 失败
        bash .github/scripts/verify-sha-consistency.sh
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

### 9.2 权限最小化矩阵

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

### 9.3 已淘汰 action

完整列表与替代方案见 **附录 B.2**。新工作流不得使用,旧工作流逐步替换(P0 安全相关 > P1 功能替代)。

### 9.4 harden-runner 统一配置

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

## 十一、MegaLinter 多语言统一 Lint

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
| java(maven 或 gradle) | `java` | ~300MB |
| kotlin(gradle 或 gradle-kts) | `java` | ~300MB(共用 java flavor,含 ktlint/detekt) |
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

## 十二、容器安全扫描

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
  uses: org/openCI/.github/workflows/pr.yml@v$MAJOR_VERSION
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
    uses: your-org/openCI/.github/workflows/pr.yml@v2
    with:
      enable-ai-review: true
    secrets:
      anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
      codecov-token: ${{ secrets.CODECOV_TOKEN }}
```

### 15.2 完整 CI/CD 链路

> **关于 outputs 的语法注意**:消费方调用 reusable workflow 时,**job 不需要也不能在自己声明 `outputs:` 段**——reusable workflow 的 outputs 由它自身的 `on.workflow_call.outputs` 声明,调用方通过 `needs.<job-id>.outputs.<key>` 直接读取。下面示例已修正。

```yaml
# .github/workflows/ci.yml（消费方仓库）
name: CI & Deploy
on:
  push:
    branches: [main]

jobs:
  build:
    # 调用 OpenCI 的 ci.yml,outputs 由该 reusable workflow 内部定义
    uses: your-org/openCI/.github/workflows/ci.yml@v2
    with:
      image-name: my-app
      run-migration: true
    secrets:
      registry-token: ${{ secrets.GITHUB_TOKEN }}

  deploy-stg:
    needs: build
    uses: your-org/openCI/.github/workflows/stg.yml@v2
    with:
      # 通过 needs.<job>.outputs.<key> 读取上游 reusable workflow 的输出
      image-digest: ${{ needs.build.outputs.image-digest }}
      run-migration: true
    secrets:
      kubeconfig-stg: ${{ secrets.KUBECONFIG_STG }}

  deploy-prd:
    needs: [build, deploy-stg]
    uses: your-org/openCI/.github/workflows/prd.yml@v2
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
    uses: your-org/openCI/.github/workflows/pr.yml@v2
    with:
      pr-review-prompt-path: .agents/skills/my-project-review.md
```

### 15.4 AI 项目扩展

```yaml
jobs:
  quality:
    uses: your-org/openCI/.github/workflows/pr.yml@v2
    with:
      enable-ai-review: true
      enable-eval: true          # prompt 变更时自动跑回归 eval
    secrets:
      anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}

  build:
    uses: your-org/openCI/.github/workflows/ci.yml@v2
    with:
      image-name: my-ai-app
      enable-ai-smoke: true      # merge 后用真实镜像跑冒烟 eval
    secrets:
      anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
```

---

## 十六、Aicert 差距来源

OpenCI 的实施优先级表(附录 A)中的 P0–P4 项均源自对 [aicert](https://github.com/YiAgent/aicert) `CI-CD-FLOW-MAP.md` 与 `CICD_PIPELINE_DESIGN.md` 的逐项差距分析。29 项差距已分别落地为本规格的对应章节(Concurrency → 5.7、Secrets Preflight → 5.x preflight 段、graceful-skip → 7.3/7.6、回滚 → 5.5、Tag 触发 → 5.5、PR Template → 17.2、CODEOWNERS → 17.3、lefthook → 17.7),不再单独维护对比表;具体来源见原始 aicert 文档与附录 A 各项标注。

---

## 十七、GitHub 原生模板与仓库约定

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

### 17.3 CODEOWNERS(主分配机制)

`.github/CODEOWNERS` 是 GitHub 原生机制——PR 涉及对应路径时**自动 request review**,无需任何 action,也是 17.6 issue auto-assign 的数据源。

**CODEOWNERS 与 auto-assign 分工**:

| 机制 | 触发 | 用途 | 与对方关系 |
| --- | --- | --- | --- |
| `CODEOWNERS` | PR 创建/同步,GitHub 原生 | 按文件路径分配领域负责人(必到位) | **主分配,优先生效** |
| `auto-assign-action`(17.6) | PR opened 事件 | 当 CODEOWNERS 未覆盖时,从 reviewer 池 round-robin 补一名 | **兜底,不与 CODEOWNERS 重复** |

实施规则:auto-assign-action 配置的 reviewer 池**应排除已在 CODEOWNERS 里的人**(在 `.github/auto-assign.yml` 的 `skipKeywords` 或显式排除列表里),避免双重指派。如果团队对 CODEOWNERS 信心足够,可以**完全省略 17.6 auto-assign**——这是更简洁的方案。


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

### 17.4 依赖自动更新:Renovate(推荐)

**决策:推荐 Renovate,而非 Dependabot**。原因:

| 能力 | Dependabot | Renovate |
| --- | --- | --- |
| 自动 pin to digest(SHA 固定) | ✗(只有版本号) | ✓ |
| 跨 manager 分组 PR(npm + GitHub Actions 一个 PR) | ✗ | ✓ |
| 自定义合并策略(patch 自动 / major 等待) | 有限 | 强 |
| 接受/忽略规则灵活度 | 弱 | 强 |
| Monorepo 支持 | 一般 | 强 |
| 配置即代码 | yaml | json5(支持注释) |

OpenCI 的"原则五:安全默认"要求 SHA 固定,Renovate 的 `pinDigests` 是该机制的关键基础设施。Dependabot 不支持 SHA pinning,这是决定性因素。

**`.github/renovate.json` 推荐配置**:

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": ["config:base", ":dependencyDashboard"],
  "packageRules": [
    {
      "matchManagers": ["github-actions"],
      "pinDigests": true,
      "labels": ["deps", "security"],
      "groupName": "github-actions"
    },
    {
      "matchUpdateTypes": ["patch", "pin", "digest"],
      "automerge": true,
      "automergeType": "pr",
      "platformAutomerge": true
    },
    {
      "matchUpdateTypes": ["major"],
      "labels": ["deps", "breaking-change"],
      "automerge": false
    }
  ],
  "schedule": ["before 6am on monday"],
  "timezone": "UTC"
}
```

**Dependabot(备选)**:已用 Dependabot 不愿迁移的团队,可在 `.github/dependabot.yml` 写最小 weekly 配置 + 额外加 `pin-github-action` CI job 兜底 SHA。

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

### 17.6 Auto Assign(可选,作为 CODEOWNERS 兜底)

> **何时使用**:CODEOWNERS 已定义路径分配规则后,`auto-assign-action` **仅作为兜底**——当 PR 修改的文件未被任何 CODEOWNERS 规则覆盖,或者 CODEOWNERS 指定的 reviewer 全部 OOO 时,从 round-robin 池里补一名 reviewer。如果你的 CODEOWNERS 覆盖足够好,**可以省略本节**。

`.github/auto-assign.yml` 配合 `kentaro/auto-assign-action`:

```yaml
addReviewers: true
addAssignees: author
# reviewer 池排除已在 CODEOWNERS 里的人,避免双重指派
reviewers:
  - charlie
  - dave
numberOfReviewers: 1
# 仅在 PR 没有任何已分配 reviewer 时触发
runOnDraft: false
useReviewGroups: false
```

### 17.7 Root 目录约定文件

必备:`README.md` / `LICENSE` / `CHANGELOG.md` / `.gitignore`。强烈推荐:`CONTRIBUTING.md` / `CODE_OF_CONDUCT.md`(Contributor Covenant) / `SECURITY.md`(GitHub Security tab 自动展示)。成熟项目可加 `GOVERNANCE.md` / `MAINTAINERS.md` / `ROADMAP.md`。

**LICENSE 选择**:工具/共享库 → Apache 2.0(对专利友好);最大化采用率 → MIT;商业控制 → BSL 或 AGPL。OpenCI 自身用 Apache 2.0。

### 17.8 security.txt(双重归属)

`.well-known/security.txt` 是安全研究人员查找漏洞报告渠道的标准文件(RFC 9116)。

**OpenCI 自身**:作为公开仓库,在 `.well-known/security.txt` 放一份,指向 OpenCI 维护者的安全报告邮箱。

**消费方**:同样应在自己的 Web 项目根 `.well-known/security.txt` 放一份(指向消费方自己的安全联系)。下面的格式既是 OpenCI 自身用,也是给消费方的模板:

```
Contact: mailto:security@example.com
Expires: 2027-01-01T00:00:00Z
Preferred-Languages: en, zh
Policy: https://example.com/security-policy
```

---

## 附录 A:实施优先级

Claude Code 按以下顺序实施,每阶段可独立验证。

### P0 — 基础设施与安全门(必备)

| # | 实施内容 | 验证方式 | 来源 |
|---|---------|---------|------|
| 1 | `manifest.yml` + `manifest-pending.yml` + `verify-sha-consistency.yml` | CI job 验证所有 workflow SHA 与 manifest 一致 | 3 章 |
| 2 | `_common/detect-language` | 在 node/python/go/java/kotlin fixture 验证输出 | 4 章 |
| 3 | **Concurrency Groups 全覆盖**(所有 workflow) | 同 PR 多次 push,验证旧 run 被取消;deploy 类不取消 | aicert #3 |
| 4 | **Secrets Preflight** + `preflight-secrets.sh` | 缺失必需 secret 时 < 30s 内 fail | aicert #6 |
| 5 | **graceful-skip 模式**(scan-snyk / scan-sonarcloud / scan-gitguardian) | token 缺席 → exit 0,PR 不阻塞 | aicert #7 |
| 6 | **PR Templates** + `CODEOWNERS` | 新 PR 验证模板自动填充、reviewer 自动 request | aicert #21 / 17.3 |
| 7 | **lefthook.yml** 本地 hook 模板(可选启用) | 本地 commit 触发,验证 ruff/eslint 在 push 前拦截 | aicert #20 |

### P1 — 主链路(开发流可用)

| # | 实施内容 | 验证方式 | 来源 |
|---|---------|---------|------|
| 8 | `pr.yml` 基础原子(lint/test/scan-deps/scan-secrets) | 示例仓库触发 PR | 5.2 |
| 9 | `claude-harness.yml` + `_common/claude-harness` composite | 手动触发,验证 sticky comment | 5.1 |
| 10 | `ci.yml` + `build-docker` / `scan-image` / `sign-image` | 验证 digest 输出 + cosign 签名 | 5.3 |
| 11 | `stg.yml` 部署链路 | 在 e2e 仓库 kind 集群验证 | 5.4 |
| 12 | **观察窗口迁移到 repository_dispatch**(替换 sleep) | 验证不占 runner 分钟 | 5.5 已知技术债 |
| 13 | **Tag 触发 prd.yml** + `environment: production` 审批门 | 打 tag 触发,验证审批阻塞 | aicert #15 / 5.5 |
| 14 | **部署回滚机制**(smoke-test 失败 → kubectl rollout undo + 开 P1 incident) | 注入失败,验证自动回滚 | aicert #11 / 5.5 |

### P2 — 完整流程

| # | 实施内容 | 验证方式 | 来源 |
|---|---------|---------|------|
| 15 | `prd.yml` 完整(`pre-check` + `check-error-rate`) | 验证错误率超阈值时阻断 | 5.5 / 7.2 |
| 16 | `security-schedule.yml` + CodeQL + SBOM + Trivy | 手动触发,验证 Security tab | 5.6 |
| 17 | `actions/integrations/notify-deploy` composite + 5 个 push 原子 | stg/prd 部署后 marker 到达各平台 | 7.8.1 |
| 18 | `actions/observability/` 全套 + `health-report.yml` | 手动触发,验证 Issue + Slack 收到日报 | 7.8.2 |
| 19 | **workflow_run 跨工作流聚合**(单条滚动评论) | 多 workflow 完成后只有一条评论 | aicert #2 |
| 20 | **环境变量漂移守卫** | CI 校验 validate-env.sh | aicert #9 |
| 21 | **coverage 阶段门槛**(stg <60% 阻塞) | 注入低覆盖率,验证阻塞 | aicert #8 |

### P3 — 辅助与生态

| # | 实施内容 | 验证方式 | 来源 |
|---|---------|---------|------|
| 22 | `community.yml` / `stale.yml` / `issue.yml` / `issue-comment.yml` | 新 contributor PR / stale issue 触发验证 | 6 章 |
| 23 | `docs-build.yml` / `docs-deploy.yml` / `release-docker.yml` | docs PR / tag 推送验证 | 19 章 |
| 24 | `.github/labeler.yml` + `auto-assign.yml`(兜底) | 验证自动 label 与兜底 reviewer | 17.5/17.6 |
| 25 | **Dependabot Auto-Merge**(patch 自动合并) | 等待 Renovate PR,验证 patch 自动合并 | aicert #22 |
| 26 | **Environment Matrix**(`infra/ENV_MATRIX.md` + Doppler 集成) | 文档化所有 env 变量分布 | aicert #24 |
| 27 | `CONTRIBUTING.md` / `CODE_OF_CONDUCT.md` / `SECURITY.md` / `.well-known/security.txt` | 检查 GitHub Security tab 展示 | 17.7/17.8 |

### P4 — Aicert 高级特性(按需引入)

| # | 实施内容 | 验证方式 | 来源 |
|---|---------|---------|------|
| 28 | **Issue→Branch 自动化**(Linear webhook 驱动) | Linear 创建 issue 触发分支创建 | aicert #1 |
| 29 | **Agent 反馈闭环**(copilot-swe-agent / codex/* 自动 @-mention) | AI agent 开 PR 失败,验证自动 mention | aicert #5 |
| 30 | **Ops 工作流**(flag-audit / health-report / agent-triage) | cron 触发验证 | aicert #4 |
| 31 | **Canary Watch / Verify Fix / Terraform Drift** | 部署后监控验证 | aicert #12-#14 |
| 32 | **AI Agent 增强**(Test Gen / Stg Autonomous Test / Changelog / Docubot / Review) | 各 workflow 单独验证 | aicert #25-#29 |
| 33 | **Gitleaks artifact 扫描** + **性能基线 (Blackfire)** | 注入泄漏 / 性能退化验证 | aicert #10 / #23 |

---

## 附录 B:禁止事项与已淘汰 Action

### B.1 禁止事项(Claude Code 实施时须检查)

1. **任何 action 直接调用 Claude API**（必须经由 `claude-harness.yml` 或 `_common/claude-harness` composite,见原则三)
2. **第三方 action 使用版本 tag**（必须用 40 位 commit SHA)
3. **SHA 在 manifest.yml 与 workflow / action 文件之间不一致**(`verify-sha-consistency` CI job 会阻断)
4. **Composite Action 调用另一个 Composite Action**（只能调用原子)
5. **工作流直接调用原子 Action**（必须经由 Composite,且 job ≙ composite)
6. **原子 Action 之间互相调用**
7. **一个 job 串多个 composite**(违反 job ≙ composite 规则)
8. **`pull_request_target` 触发器 checkout PR head 代码后执行**（供应链安全风险)
9. **自实现 Docker 构建、secret 扫描、覆盖率上报等有成熟方案的功能**
10. **在 `stg.yml` 之前直接触发 `prd.yml`**（必须经过观察窗口)
11. **省略 `harden-runner` 步骤**（每个 job 必须加载)
12. **`prd.yml` 的 deploy-k8s job 缺 `environment: production`**(GitHub Environment 审批门必须生效)
13. **任何占位 SHA(`1234...` 或 `<待验证 SHA>`)出现在 `manifest.yml` 主 deps 段**(只能在 `manifest-pending.yml`)

### B.2 已淘汰 Action(禁止使用,从 manifest.yml 移除)

| Action | 淘汰原因 | 替代方案 |
| --- | --- | --- |
| `semgrep/semgrep-action` | 2020 年停更,不再维护 | `pip install semgrep && semgrep ci`(经 setup-python 安装) |
| `amondnet/vercel-action` | 版本严重滞后(v25 vs 最新 v42.3.0),功能不全 | 官方 Vercel CLI: `npm i -g vercel && vercel deploy --prod` |
| `trufflesecurity/trufflehog@main` | 引用 `main` 分支,供应链风险 | 固定到发布版本 SHA(在 `manifest.yml`/`manifest-pending.yml` 中维护) |
| `actions/stale` | 仓库已归档,不再接收 bug fix | `stale-org/stale`(社区维护 fork) |

迁移策略:已有工作流中的淘汰 action 逐步替换,优先级 P0(安全相关)> P1(功能替代)。替换时同步更新 `manifest.yml` 中的 SHA。

---

## 十八、测试策略

OpenCI 测试分三层金字塔:**Action 单元测试**(大量,bats-core,80%+ shell 脚本覆盖)→ **Workflow 测试**(中量,act 本地,关键路径)→ **E2E**(少量,独立测试仓库,完整消费方集成)。OpenCI 自身 CI(`test-openCI.yml`)在 PR 上跑 bats + verify-sha-consistency。

### 18.1 Action 级别测试

每个 composite action 和原子 action 使用 [bats-core](https://github.com/bats-core/bats-core) 进行单元测试:

```bash
# tests/actions/detect-language.bats
@test "detects node project" {
  cd fixtures/node-project
  run bash $ACTION_PATH/action.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"language=node"* ]]
  [[ "$output" == *"package-manager=npm"* ]]
}

@test "detects python project with uv" {
  cd fixtures/python-uv-project
  run bash $ACTION_PATH/action.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"language=python"* ]]
  [[ "$output" == *"package-manager=uv"* ]]
}
```

**测试目录结构**:
```
tests/
├── actions/
│   ├── *.bats              # 一个 action 一个 bats 文件
│   └── fixtures/           # node/python-uv/go/java-maven/java-gradle/
│                           # kotlin-gradle-kts/unknown-project 各一个
└── scripts/
    ├── preflight-secrets.bats
    └── verify-sha-consistency.bats
```

### 18.2 Workflow 级别测试(act 的能与不能)

使用 [act](https://github.com/nektos/act) 在本地模拟 GitHub Actions 运行,但 act 对 OpenCI **核心能力的覆盖有限**,务必在 18.3 e2e 中补齐验证。

**act 适用场景**(可放心用):

```bash
# 单 job 内的 step 序列(如 detect-language 的 shell 逻辑)
act -j detect-language --container-architecture linux/amd64

# 单 workflow 内多 job 串行(如 pr.yml 的 lint → test → coverage)
act pull_request \
  -s ANTHROPIC_API_KEY=test-key \
  -s CODECOV_TOKEN=test-token \
  --container-architecture linux/amd64
```

**act 不支持的场景**(必须用 e2e 仓库验证):

| 功能 | act 支持度 | 必须用 e2e 验证 |
| --- | --- | --- |
| `uses: org/repo/.github/workflows/x.yml@ref` (跨仓库 reusable workflow) | ❌ 不支持 | ✓ |
| OIDC `id-token` 与 cosign 签名 | ❌ 不支持 | ✓ |
| `environment: production` 审批门 | ❌ 不支持 | ✓ |
| `workflow_run` 触发器 | ❌ 不支持 | ✓ |
| `repository_dispatch` 触发器 | ⚠️ 部分支持 | ✓ |
| `concurrency.cancel-in-progress` | ⚠️ 不准确 | ✓ |
| `permissions` 块(GITHUB_TOKEN scope 限制) | ❌ 行为不一致 | ✓ |
| GitHub Container Registry 真实推送 | ⚠️ 需 mock | ✓ |
| Cron schedule 触发 | ⚠️ 仅手动模拟 | — |
| Secrets fan-out / job-level secrets inheritance | ⚠️ 行为差异 | ✓ |

**act 的实际定位**:开发者本地快速验证 shell 逻辑、单文件调整、原子 action 输入输出契约。**不能替代 CI**,也**不能验证 OpenCI 作为 reusable workflow 库的核心价值**。

**测试金字塔分工**(基于上表)→ 见 18.3 e2e 仓库覆盖。

### 18.3 端到端测试(基础设施详解)

在独立的测试仓库 `openCI-e2e` 中验证完整的消费方集成,覆盖 18.2 表格中 act 不支持的所有场景。

**测试仓库结构**:
```
openCI-e2e/
├── .github/workflows/
│   ├── test-pr.yml          # 触发 OpenCI pr.yml
│   ├── test-ci.yml          # 触发 OpenCI ci.yml(带 OIDC + cosign)
│   ├── test-stg.yml         # 触发 OpenCI stg.yml(带 kind 集群)
│   ├── test-prd.yml         # 触发 OpenCI prd.yml(带 environment 审批)
│   ├── test-community.yml
│   └── test-health-report.yml
├── src/app.js               # 简单 Node.js 应用,产出已知 bug 与已知 metric
├── tests/app.test.js
├── e2e/
│   ├── kind-config.yaml     # kind K8s 集群定义
│   └── docker-compose.yml   # mock registry / mock Sentry endpoint
├── Dockerfile
└── package.json
```

**基础设施准备**(每个 e2e workflow 内部完成):前置 `setup-k8s` job 用 `helm/kind-action` 启 kind 集群,kind export kubeconfig 后 base64 编码 + `::add-mask::` 后塞到 step output;后续 `test-stg` job `needs: setup-k8s`,`uses: ./.github/workflows/stg.yml`,通过 `secrets.kubeconfig-stg: ${{ needs.setup-k8s.outputs.kubeconfig }}` 传递。

**关键基础设施组件**:

| 组件 | 准备方式 | 备注 |
| --- | --- | --- |
| K8s 集群 | `helm/kind-action` 启 kind 集群 | 每次 run 全新,免维护 |
| kubeconfig | kind 自动生成,base64 后传给 stg.yml | 测试用,不接触真实集群 |
| Container Registry | 用 GHCR `ghcr.io/<test-org>/openCI-e2e-app` | 测试镜像,定期清理 |
| Sentry | mock endpoint(`docker compose up sentry-mock`)+ 录制的 fixture 响应 | 不消耗真实 Sentry quota |
| PostHog/Datadog/LangSmith/Axiom | mock endpoint,验证 HTTP 调用结构 | 同上 |
| AI 调用 | `enable-ai-review: false` + `ANTHROPIC_API_KEY=test-key` | 走 graceful-skip 路径,不消耗 token |
| OIDC + cosign | 真实 GitHub OIDC + 真实 cosign(GHCR 推送) | 这必须真实跑,无法 mock |
| `environment: production` | 在 e2e 仓库 GitHub 设置一个 `production-test` environment,**不配置 reviewers** | 验证审批门触发但自动通过 |

**触发频率**:

- 每次 `main` 分支 push:跑 `test-pr` + `test-ci`(快路径,~5 分钟)
- 每天 UTC 02:00:跑全套(`test-stg` / `test-prd` / `test-community` / `test-health-report`,~25 分钟)
- 每周一 UTC 02:00:跑全套 + `security-schedule.yml`(~40 分钟)

**真实 AI 调用 smoke test**:每周一次单独 workflow,用真实 `ANTHROPIC_API_KEY`(测试团队的低额度 key)跑一次 AI review / triage / health-report,验证 prompt 没坏。预算上限 $1/周。

---

## 十九、缺失工作流规格

### 19.1 docs-build.yml

**触发**:`pull_request` paths `docs/**` / `*.md`。**Job**:`build`(timeout 5 min)→ checkout → 按文档框架构建(MkDocs `mkdocs build --strict` / Docusaurus `npm run build`)→ `npx markdown-link-check docs/**/*.md` 验证链接。

### 19.2 docs-deploy.yml

**触发**:`push: branches: [main]` paths `docs/**` / `*.md` + `workflow_dispatch`。**Permissions**:`contents:read` / `pages:write` / `id-token:write`。**Environment**:`github-pages`。**Job**:`deploy`(timeout 10 min)→ checkout → build → `actions/upload-pages-artifact` → `actions/deploy-pages`。

### 19.3 release-docker.yml

**触发**:`push: tags: ['v*']` + `workflow_dispatch`(input `tag`)。**Permissions**:`contents:read` / `packages:write`。**Timeout**:20 min。**Steps**(标准 GHCR 推送序列):`actions/checkout` → `docker/setup-buildx-action` → `docker/login-action`(registry=ghcr.io, password=`GITHUB_TOKEN`)→ `docker/metadata-action`(tags: semver `{{version}}` / `{{major}}.{{minor}}` / `type=sha`)→ `docker/build-push-action`(`push: true`,`cache-from/to: type=gha,mode=max`)。

---

## 二十、成本意识

OpenCI 的 AI 步骤(PR review / issue triage / smoke eval / health report)按 Claude Sonnet 定价,典型中型团队(50 PR/月)月度成本约 $15。**消费方应**:启用 prompt caching、对 triage 等简单任务用 Haiku、为非关键 PR 关闭 `enable-ai-review`。具体 token 用量随 prompt / 仓库规模波动,以实际账单为准——本规格不维护静态成本表(易过期)。

---

## 二十一、EvolveCI 关系

OpenCI 是**通用 CI/CD 基础层**(lint / test / build / deploy / security / observability)。EvolveCI 是**应用层**——通过 `uses: openCI/.github/workflows/*.yml@v2` 引用 OpenCI,在其上扩展 AI Agent 特化能力(prompt 版本管理、agent 自主测试、LLM 成本追踪、prompt eval 回归增强)。OpenCI 不感知也不依赖 EvolveCI;EvolveCI 的所有扩展走标准消费方集成模式,无特殊耦合。

---

## 二十二、CHANGELOG 非 PR 变更

`release-drafter` 基于 PR 生成 CHANGELOG。Hotfix 直推 main / tag 触发发布 / 手动 cherry-pick **必须补一个追溯 PR**(label `hotfix`)以保留 changelog 条目;在 `release-drafter.yml` 加 `exclude-labels: ['hotfix', 'skip-changelog']` 让 hotfix 单独分组而非污染主 changelog。

---

## 附录 C:SHA 一致性验证脚本

`.github/scripts/verify-sha-consistency.sh` 是 P0 必备 CI job(挂在 `pr.yml` / `ci.yml` 的 preflight 之后),职责:

1. 扫描所有 `.github/workflows/*.yml` 与 `actions/**/*.yml` 中的 `uses: <action>@<SHA>` 行
2. 比对每条引用的 SHA 与 `manifest.yml` 的 `deps:` 段,不一致则 `exit 1`
3. 拒绝 `@v*` / `@main` / `@master` 形式的 tag/branch 引用(必须 40 位 SHA)
4. 拒绝 `manifest-pending.yml` 中的条目被实际使用(未验证 SHA 不进仓库)
5. 拒绝附录 B 已淘汰 action 仍被使用

实现细节(yq + bash 扫描)见仓库内的实际脚本文件,不在本规格中维护。
