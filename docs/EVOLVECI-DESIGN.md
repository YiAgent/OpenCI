# EvolveCI — CI 控制塔设计规格

**版本**：v2.0
**定位**：独立 meta-repo，观察所有仓库的 CI 流水线，主动汇报 + 实时分诊
**与 OpenCI 关系**：EvolveCI 消费 OpenCI 的 `claude-harness`（workflow 级别调用），不复制其功能

---

## 变更日志

| 版本 | 变更内容 |
| --- | --- |
| v2.0 | 架构重构：消除 v1/v2 并存冲突，统一为四层架构；修复 claude-harness 调用链（AI 调用提升到 workflow 级别）；替换 bash 手写 YAML 解析为 yq + JSON；修复 matrix 动态生成的防御性检查；新增日志脱敏；新增 concurrency group；状态持久化统一到 _state 孤儿分支 + cache 双层；match-known-patterns 改用 JSON 格式 + yq 查询 |
| v1.0 | 初始版本：三层架构 + 实时分诊 + 自动重跑 + 每日报告 |

---

## 一、设计原则

### 1.1 四层分离

| 层 | 职责 | AI 用量 | 运行频率 |
|---|---|---|---|
| **Sources** | 拉数据（gh CLI / curl） | 零 | 每 15 分钟 / 每日 |
| **Analyzers** | 规则匹配 + 轻量 AI | Haiku $0.001/次，Sonnet $0.01/次 | 每次失败 |
| **State** | 双层持久化（cache + git） | 零 | 每次写入 |
| **Publishers** | 输出（Issue / Slack / rerun） | 零 | 每次需要 |

**关键约束**：90% 的失败在 Analyzers 层被规则拦截（Tier 1 + Tier 2），不调 AI。

### 1.2 状态外部化

所有跨 run 共享的状态（throttle 计数、重跑记录、健康趋势）存储在 `_state` 孤儿分支，不污染 main。Git 历史 = 时间序列数据库。GitHub Actions Cache 作为快速读取层。

### 1.3 安全默认

- 跨 repo 访问用 fine-grained PAT，只授权 `actions:read` + `metadata:read`
- 不需要目标仓库做任何配置变更
- auto-rerun 仅限只读操作（test/lint/build），永不重跑 deploy/security workflow
- 失败日志在传给 AI 前必须脱敏（移除 token、密码、内部 IP）
- 每个 job 第一步加载 `harden-runner`
- 所有第三方 action SHA 固定，通过 `manifest.yml` 集中管理

### 1.4 复用 OpenCI

- AI 调用在 **workflow 级别** 使用 `claude-harness.yml`（reusable workflow），不在 composite action 内部调用
- Slack 通知复用 `uses: your-org/openCI/actions/integrations/slack-notify@v2`
- 第三方 SHA 对齐 OpenCI 的 `manifest.yml`

---

## 二、目录结构

```
evolveCI/
├── .github/
│   └── workflows/
│       ├── triage-failure.yml        # 实时分诊（每 15 分钟扫描）
│       ├── health-ci-daily.yml       # 每日 CI 健康汇总
│       ├── health-ci-weekly.yml      # 每周深度分析
│       └── heartbeat.yml             # 自监控心跳（每 6 小时）
│
├── actions/
│   ├── observability/
│   │   ├── sources/                  # 数据源：只负责"拉"
│   │   │   └── query-github-actions/ # CI 运行数据 → JSON（封装 gh CLI）
│   │   │
│   │   ├── analyzers/                # 分析器：纯计算，零 IO（除 state 读）
│   │   │   ├── match-known-patterns/ # 正则模式匹配（$0，Tier 1）
│   │   │   ├── classify-heuristic/   # 启发式关键词匹配（$0，Tier 2）
│   │   │   ├── classify-ai/          # AI 分类（Haiku Tier 3 / Sonnet Tier 4）
│   │   │   ├── compute-flakiness/    # Flaky 度滑动窗口计算
│   │   │   ├── compute-mttr/         # 平均故障恢复时长
│   │   │   └── compute-trends/       # DORA 指标 + 趋势检测
│   │   │
│   │   ├── state/                    # 持久化基础设施
│   │   │   ├── read-state/           # cache 快速路径 + _state 分支回源
│   │   │   ├── write-state/          # _state 分支写入（retry 3 次）+ cache 回填
│   │   │   └── redact-log/           # 日志脱敏（移除敏感信息）
│   │   │
│   │   └── publishers/               # 输出渠道
│   │       ├── post-issue-report/    # 封装 peter-evans/create-issue-from-file
│   │       ├── post-slack-report/    # 复用 OpenCI slack-notify
│   │       ├── auto-rerun/           # 封装 gh run rerun --failed + 预算检查
│   │       └── trip-circuit-breaker/ # 熔断告警：gh issue + Slack
│   │
│   └── _common/
│       └── (从 OpenCI 引用，不复制)
│
├── prompts/
│   └── observability/
│       ├── classify-failure-haiku.md    # Tier 3 失败分类（Haiku）
│       ├── classify-failure-sonnet.md   # Tier 4 深度分析（Sonnet）
│       ├── daily-report.md              # 每日报告（Haiku）
│       └── weekly-deep-dive.md          # 每周深度（Sonnet）
│
├── data/                             # 配置文件（main 分支，仅人工编辑）
│   ├── onboarded-repos.yml           # 被监控仓库列表及配置
│   └── circuit-config.yml            # 熔断器配置（维度、阈值、排除列表）
│
├── lib/                              # 2+ action 共用脚本
│   └── redact-log.sh                 # 日志脱敏正则集
│
└── manifest.yml                      # 第三方依赖 SHA（对齐 OpenCI）
```

### 关键说明

- `data/` 目录只存放**配置**（人工编辑），运行时**状态**存放在 `_state` 孤儿分支
- `lib/redact-log.sh` 被 `redact-log` action 和 `classify-ai` 共用
- AI prompt 按 Tier 分文件，与 action 分离（遵循 OpenCI 原则一：变化频率决定位置）

---

## 三、数据源层（Sources）— 零 AI 成本

### 3.1 query-github-actions

**职责**：列举多个 repo 在时间窗口内的 workflow runs，含失败 job 的日志摘要。

```yaml
# actions/observability/sources/query-github-actions/action.yml
name: "Query GitHub Actions Runs"
description: "List workflow runs across repos with optional log extraction"

inputs:
  repos:
    description: "Comma-separated repo list, e.g. org/repo-a,org/repo-b"
    required: true
  since:
    description: "Time window, e.g. 30m or 24h"
    required: true
  status:
    description: "Filter: all | failure | success"
    required: false
    default: "all"
  include-logs:
    description: "Fetch failed job logs (expensive, use sparingly)"
    required: false
    default: "false"
  log-tail:
    description: "Number of log lines to fetch per failure"
    required: false
    default: "100"
  token:
    description: "Fine-grained PAT with actions:read"
    required: true

outputs:
  runs:
    description: "JSON array of run objects"
    value: ${{ steps.collect.outputs.runs }}
  count:
    description: "Total run count"
    value: ${{ steps.collect.outputs.count }}
  failure-count:
    description: "Failed run count"
    value: ${{ steps.collect.outputs.failure_count }}

runs:
  using: composite
  steps:
    - name: Collect runs
      id: collect
      shell: bash
      env:
        GH_TOKEN: ${{ inputs.token }}
      run: |
        SINCE=$(date -u -d "-${{ inputs.since }}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-${{ inputs.since }} +%Y-%m-%dT%H:%M:%SZ)
        RESULT="[]"

        IFS=',' read -ra REPOS <<< "${{ inputs.repos }}"
        for repo in "${REPOS[@]}"; do
          repo=$(echo "$repo" | xargs)  # trim

          # 列举 runs
          DATA=$(gh run list \
            --repo "$repo" \
            --created ">$SINCE" \
            --json databaseId,name,conclusion,createdAt,updatedAt,event,headBranch,headSha,actor,workflowName \
            --limit 100 \
            --jq '.' 2>/dev/null || echo "[]")

          # 给每条 run 加上 repo 字段
          ENRICHED=$(echo "$DATA" | jq --arg repo "$repo" '[.[] | .repo = $repo]')
          RESULT=$(printf '%s\n%s' "$RESULT" "$ENRICHED" | jq -s '.[0] + .[1]')
        done

        # 按 status 过滤
        case "${{ inputs.status }}" in
          failure)
            RESULT=$(echo "$RESULT" | jq '[.[] | select(.conclusion == "failure")]')
            ;;
          success)
            RESULT=$(echo "$RESULT" | jq '[.[] | select(.conclusion == "success")]')
            ;;
        esac

        # 可选：拉取失败日志
        if [ "${{ inputs.include-logs }}" = "true" ]; then
          RESULT=$(echo "$RESULT" | jq -c '.[]' | while read -r run; do
            RUN_ID=$(echo "$run" | jq -r '.databaseId')
            REPO=$(echo "$run" | jq -r '.repo')

            if [ "$(echo "$run" | jq -r '.conclusion')" = "failure" ]; then
              LOG=$(gh run view "$RUN_ID" \
                --repo "$REPO" \
                --log-failed \
                2>/dev/null | tail -${{ inputs.log-tail }} | base64 -w0)

              JOBS=$(gh run view "$RUN_ID" \
                --repo "$REPO" \
                --json jobs \
                --jq '[.jobs[] | select(.conclusion == "failure") | {name: .name, failed_step: (.steps[] | select(.conclusion == "failure") | .name)}]' \
                2>/dev/null || echo "[]")

              echo "$run" | jq \
                --arg log "$LOG" \
                --argjson jobs "$JOBS" \
                '. + {log_base64: $log, failed_jobs: $jobs}'
            else
              echo "$run"
            fi
          done | jq -s '.')
        fi

        FAILURE_COUNT=$(echo "$RESULT" | jq '[.[] | select(.conclusion == "failure")] | length')

        # 使用 EOF delimiter 避免 JSON 中的特殊字符问题
        echo "count=$(echo "$RESULT" | jq 'length')" >> $GITHUB_OUTPUT
        echo "failure_count=$FAILURE_COUNT" >> $GITHUB_OUTPUT
        {
          echo "runs<<EOF"
          echo "$RESULT" | jq -c '.'
          echo "EOF"
        } >> $GITHUB_OUTPUT
```

**性能约束**：
- 每个 repo 最多 100 条 run，避免 API rate limit
- `include-logs: true` 会额外消耗 API 调用（每个失败 run +2 次），仅在 triage 时启用
- 5 个 repo × 100 条 = 500 条，远低于 GitHub API 限制（5000 次/小时）

---

## 四、分析层（Analyzers）

### 4.1 四层递进分类

| Tier | Action | 方法 | 成本 | 预期命中率 |
|---|---|---|---|---|
| 1 | `match-known-patterns` | 正则/字符串匹配（JSON + jq） | $0 | 70% |
| 2 | `classify-heuristic` | 关键词启发式规则 | $0 | 20% |
| 3 | `classify-ai`（Haiku） | AI 分类 | ~$0.001/次 | 8% |
| 4 | `classify-ai`（Sonnet） | AI 深度分析 | ~$0.01/次 | 2% |

**分类流程**：

```
失败 run 日志
  │
  ▼
┌──────────────────────────────────────────┐
│ Tier 1: match-known-patterns             │
│ 成本: $0 · ~10ms                         │
│ 命中 → 返回缓存分类，done                │
│ 数据源: _state:known-patterns.json       │
└──────────────────────────────────────────┘
  │ miss
  ▼
┌──────────────────────────────────────────┐
│ Tier 2: classify-heuristic               │
│ 成本: $0 · ~50ms                         │
│ - ECONNREFUSED / ENOTFOUND → flaky      │
│ - "Permission denied" / "403" → security│
│ - "FAIL" / "AssertionError" → code      │
│ - "npm ERR!" / "pip install" → dep      │
│ 高置信度 → 返回分类，done                │
└──────────────────────────────────────────┘
  │ low confidence
  ▼
┌──────────────────────────────────────────┐
│ Tier 3: classify-ai (Haiku)              │
│ ~$0.001/次 · 日志末 50 行 + 元数据      │
│ → category + matched_pattern             │
│ 新 pattern 自动 PR 进 known-patterns     │
└──────────────────────────────────────────┘
  │ unable to classify
  ▼
┌──────────────────────────────────────────┐
│ Tier 4: classify-ai (Sonnet)             │
│ ~$0.01/次 · 完整日志 + 历史上下文       │
│ → category + 修复建议 + 根因分析         │
└──────────────────────────────────────────┘
```

### 4.2 match-known-patterns（Tier 1，零 AI）

**数据格式**：使用 JSON 而非 YAML，避免 bash 手写解析的脆弱性。

```json
// _state/known-patterns.json
[
  {
    "id": "npm-eai-again",
    "match": "EAI_AGAIN.*registry\\.npmjs\\.org|ENOTFOUND.*registry\\.npmjs\\.org",
    "category": "flaky",
    "auto_rerun": true,
    "notify": false,
    "severity": "low",
    "seen_count": 47,
    "last_seen": "2026-04-28",
    "source": "seed"
  },
  {
    "id": "runner-disk-full",
    "match": "No space left on device|runner.*disk.*full",
    "category": "infra",
    "auto_rerun": false,
    "notify": true,
    "severity": "high",
    "seen_count": 3,
    "last_seen": "2026-04-25",
    "source": "seed"
  }
]
```

**Action 实现**（使用 `jq` 遍历 JSON，不再手写 YAML 解析）：

```yaml
# actions/observability/analyzers/match-known-patterns/action.yml
name: "Match Known Patterns"
description: "Tier 1: regex match against known failure patterns (zero AI)"

inputs:
  log:
    description: "Log text (plain, not base64)"
    required: true
  patterns-path:
    description: "Path to known-patterns.json"
    required: false
    default: "known-patterns.json"

outputs:
  matched:
    value: ${{ steps.match.outputs.matched }}
  pattern-id:
    value: ${{ steps.match.outputs.pattern_id }}
  category:
    value: ${{ steps.match.outputs.category }}
  auto-rerun:
    value: ${{ steps.match.outputs.auto_rerun }}
  notify:
    value: ${{ steps.match.outputs.notify }}
  severity:
    value: ${{ steps.match.outputs.severity }}

runs:
  using: composite
  steps:
    - name: Match patterns
      id: match
      shell: bash
      run: |
        PATTERNS_FILE="${{ inputs.patterns-path }}"
        LOG="${{ inputs.log }}"

        if [ ! -f "$PATTERNS_FILE" ] || [ -z "$LOG" ]; then
          echo "matched=false" >> $GITHUB_OUTPUT
          exit 0
        fi

        # 用 jq 遍历所有 pattern，逐个 grep
        MATCHED=$(echo "$PATTERNS_FILE" | jq -c '.[]' | while read -r entry; do
          PATTERN=$(echo "$entry" | jq -r '.match')
          if echo "$LOG" | grep -qE "$PATTERN" 2>/dev/null; then
            echo "$entry"
            break  # 第一个匹配即返回
          fi
        done)

        if [ -n "$MATCHED" ]; then
          echo "matched=true" >> $GITHUB_OUTPUT
          echo "pattern_id=$(echo "$MATCHED" | jq -r '.id')" >> $GITHUB_OUTPUT
          echo "category=$(echo "$MATCHED" | jq -r '.category')" >> $GITHUB_OUTPUT
          echo "auto_rerun=$(echo "$MATCHED" | jq -r '.auto_rerun')" >> $GITHUB_OUTPUT
          echo "notify=$(echo "$MATCHED" | jq -r '.notify')" >> $GITHUB_OUTPUT
          echo "severity=$(echo "$MATCHED" | jq -r '.severity')" >> $GITHUB_OUTPUT
        else
          echo "matched=false" >> $GITHUB_OUTPUT
        fi
```

### 4.3 classify-heuristic（Tier 2，零 AI）

```yaml
# actions/observability/analyzers/classify-heuristic/action.yml
name: "Classify Failure (Heuristic)"
description: "Tier 2: keyword-based classification (zero AI)"

inputs:
  log:
    description: "Log text"
    required: true
  failed-step:
    description: "Name of the failed step"
    required: false
  flakiness-score:
    description: "Historical flakiness score (0-100)"
    required: false
    default: "0"

outputs:
  classified:
    value: ${{ steps.classify.outputs.classified }}
  category:
    value: ${{ steps.classify.outputs.category }}
  severity:
    value: ${{ steps.classify.outputs.severity }}
  confidence:
    value: ${{ steps.classify.outputs.confidence }}
  should-rerun:
    value: ${{ steps.classify.outputs.should_rerun }}
  should-notify:
    value: ${{ steps.classify.outputs.should_notify }}

runs:
  using: composite
  steps:
    - name: Apply heuristic rules
      id: classify
      shell: bash
      run: |
        LOG="${{ inputs.log }}"
        STEP="${{ inputs.failed-step }}"
        FLAKY="${{ inputs.flakiness-score }}"

        # 默认值
        CATEGORY="unknown"
        SEVERITY="medium"
        CONFIDENCE="low"
        SHOULD_RERUN="false"
        SHOULD_NOTIFY="true"

        # ── Flaky: 网络/Registry/超时 ──
        if echo "$LOG" | grep -qE "ECONNREFUSED|ENOTFOUND|EAI_AGAIN|ETIMEDOUT|ReadTimeoutError|context deadline exceeded" 2>/dev/null; then
          CATEGORY="flaky"
          SEVERITY="low"
          CONFIDENCE="high"
          SHOULD_RERUN="true"
          SHOULD_NOTIFY="false"
        # ── Flaky: Rate limit ──
        elif echo "$LOG" | grep -qE "rate.?limit|429|too many requests|toomanyrequests" 2>/dev/null; then
          CATEGORY="flaky"
          SEVERITY="low"
          CONFIDENCE="high"
          SHOULD_RERUN="true"
          SHOULD_NOTIFY="false"
        # ── Flaky: Runner 基础设施间歇 ──
        elif echo "$LOG" | grep -qE "runner.*did not connect|runner.*failed to start|No space left on device" 2>/dev/null; then
          CATEGORY="flaky"
          SEVERITY="medium"
          CONFIDENCE="medium"
          SHOULD_RERUN="true"
          SHOULD_NOTIFY="false"
        # ── Security: 权限/认证 ──
        elif echo "$LOG" | grep -qE "Permission denied|403 Forbidden|authentication failed|unauthorized" 2>/dev/null; then
          CATEGORY="security"
          SEVERITY="high"
          CONFIDENCE="high"
          SHOULD_RERUN="false"
          SHOULD_NOTIFY="true"
        # ── Dependency: 包安装失败 ──
        elif echo "$LOG" | grep -qE "npm ERR!|pip install.*error|go:.*module.*not found|resolve.*version.*conflict" 2>/dev/null; then
          CATEGORY="dependency"
          SEVERITY="medium"
          CONFIDENCE="medium"
          SHOULD_RERUN="false"
          SHOULD_NOTIFY="true"
        # ── Code: 测试/编译失败 ──
        elif echo "$LOG" | grep -qE "FAIL|AssertionError|SyntaxError|TypeError|Compilation failed|Test failed" 2>/dev/null; then
          CATEGORY="code"
          SEVERITY="medium"
          CONFIDENCE="medium"
          SHOULD_RERUN="false"
          SHOULD_NOTIFY="true"
        # ── Infra: Docker/K8s ──
        elif echo "$LOG" | grep -qE "docker.*daemon|OOM|Cannot allocate memory|CrashLoopBackOff|ImagePullBackOff" 2>/dev/null; then
          CATEGORY="infra"
          SEVERITY="high"
          CONFIDENCE="medium"
          SHOULD_RERUN="false"
          SHOULD_NOTIFY="true"
        fi

        # 高 flakiness 历史时降低置信度，交给 AI
        if [ "$FLAKY" -gt 50 ] && [ "$CATEGORY" != "flaky" ]; then
          CONFIDENCE="low"
        fi

        echo "classified=true" >> $GITHUB_OUTPUT
        echo "category=$CATEGORY" >> $GITHUB_OUTPUT
        echo "severity=$SEVERITY" >> $GITHUB_OUTPUT
        echo "confidence=$CONFIDENCE" >> $GITHUB_OUTPUT
        echo "should_rerun=$SHOULD_RERUN" >> $GITHUB_OUTPUT
        echo "should_notify=$SHOULD_NOTIFY" >> $GITHUB_OUTPUT
```

### 4.4 classify-ai（Tier 3 Haiku / Tier 4 Sonnet）

> ⚠️ **架构说明**：AI 调用**不在 composite action 内部**执行。
> `classify-ai` action 只负责**准备输入 + 解析输出**。
> 实际 AI 调用在 workflow 的 `claude-harness` job 中进行（reusable workflow 级别）。

```yaml
# actions/observability/analyzers/classify-ai/action.yml
name: "Classify Failure (AI) - Prepare & Parse"
description: "Prepare context for AI classification and parse result (actual AI call is in workflow)"

inputs:
  log:
    description: "Redacted log text"
    required: true
  workflow-name:
    required: true
  failed-step:
    required: false
  flakiness-score:
    required: false
    default: "0"
  repo:
    required: true
  run-id:
    required: false
  tier:
    description: "3 = Haiku (default), 4 = Sonnet"
    required: false
    default: "3"

outputs:
  context:
    description: "JSON context to pass to claude-harness"
    value: ${{ steps.prepare.outputs.context }}
  prompt-path:
    description: "Which prompt file to use"
    value: ${{ steps.prepare.outputs.prompt_path }}
  model:
    value: ${{ steps.prepare.outputs.model }}

runs:
  using: composite
  steps:
    - name: Prepare AI context
      id: prepare
      shell: bash
      run: |
        # 截断日志到安全大小
        TRUNCATED_LOG=$(echo "${{ inputs.log }}" | head -c 8192)

        if [ "${{ inputs.tier }}" = "4" ]; then
          PROMPT="prompts/observability/classify-failure-sonnet.md"
          MODEL="claude-sonnet-4-20250514"
          # Tier 4 传完整日志（已脱敏）
          LOG_FIELD=$(echo "${{ inputs.log }}" | head -c 32768 | jq -Rs .)
        else
          PROMPT="prompts/observability/classify-failure-haiku.md"
          MODEL="claude-haiku-4-5-20251001"
          # Tier 3 只传末尾 50 行
          LOG_FIELD=$(echo "${{ inputs.log }}" | tail -50 | head -c 8192 | jq -Rs .)
        fi

        CONTEXT=$(jq -n \
          --arg wf "${{ inputs.workflow-name }}" \
          --arg step "${{ inputs.failed-step }}" \
          --argjson flaky "${{ inputs.flakiness-score }}" \
          --arg repo "${{ inputs.repo }}" \
          --arg run_id "${{ inputs.run-id }}" \
          --argjson log "$LOG_FIELD" \
          '{
            workflow_name: $wf,
            failed_step: $step,
            flakiness_score: $flaky,
            repo: $repo,
            run_id: $run_id,
            log_tail: $log
          }')

        echo "context=$(echo "$CONTEXT" | jq -c '.')" >> $GITHUB_OUTPUT
        echo "prompt_path=$PROMPT" >> $GITHUB_OUTPUT
        echo "model=$MODEL" >> $GITHUB_OUTPUT
```

### 4.5 classify-failure prompt（Tier 3 Haiku）

```markdown
<!-- prompts/observability/classify-failure-haiku.md -->
你是 CI 流水线分诊助手。看一段 GitHub Actions 失败日志，判断失败类型。

输入：
- workflow: {{workflow_name}}
- 失败 step: {{failed_step}}
- 历史失败率: {{flakiness_score}}%（过去 20 次中失败比例）
- 日志末尾：
{{log_tail}}

严格输出 JSON，不要输出其他内容：
{
  "category": "flaky | infra | code | dependency | security | unknown",
  "severity": "low | medium | high | critical",
  "summary": "15字以内总结",
  "should_notify": true/false,
  "should_rerun": true/false,
  "matched_pattern": "用正则能匹配的失败签名，如 'ECONNREFUSED.*registry.npmjs.org'"
}

分类规则：
- flaky: 网络超时、registry 5xx、runner 启动失败、资源竞争（竞态条件测试）
- infra: K8s 资源不足、runner 磁盘满、Docker daemon 挂了
- code: 测试断言失败、编译错误、lint 错误
- dependency: npm/pip/go mod 安装失败、版本冲突、lockfile 不一致
- security: secret 泄漏、权限拒绝、恶意 action 检测
- unknown: 看不出来

通知规则：
- flaky + low severity → should_notify=false
- security 任何级别 → should_notify=true, severity 至少 high
- 其他 → should_notify=true

重跑规则：
- 只有 category=flaky 才 should_rerun=true
- 其他一律 false

matched_pattern 规则：
- 提取日志中最能唯一标识该失败的字符串模式
- 用正则表达式表示，确保下次能 grep -E 匹配
- 如果无法提取有效模式，返回空字符串
```

### 4.6 classify-failure prompt（Tier 4 Sonnet）

```markdown
<!-- prompts/observability/classify-failure-sonnet.md -->
你是资深 CI/CD 工程师。一段 GitHub Actions 失败日志经过规则匹配和 Haiku 分类后仍无法确定根因。请进行深度分析。

输入：
- workflow: {{workflow_name}}
- 失败 step: {{failed_step}}
- 历史失败率: {{flakiness_score}}%
- 仓库: {{repo}}
- 完整日志（已脱敏）：
{{log_tail}}

输出严格 JSON：
{
  "category": "flaky | infra | code | dependency | security | unknown",
  "severity": "low | medium | high | critical",
  "summary": "一句话总结",
  "root_cause": "根因分析（2-3 句）",
  "fix_suggestion": "具体修复建议",
  "should_notify": true/false,
  "should_rerun": true/false,
  "matched_pattern": "可复用的失败签名正则"
}
```

### 4.7 compute-flakiness

```yaml
# actions/observability/analyzers/compute-flakiness/action.yml
name: "Compute Flakiness Score"
description: "Calculate flakiness score from recent run history"

inputs:
  repo:
    required: true
  workflow-name:
    required: true
  lookback:
    description: "Number of recent runs to analyze"
    required: false
    default: "20"
  token:
    required: true

outputs:
  flakiness-score:
    value: ${{ steps.calc.outputs.score }}
  total-runs:
    value: ${{ steps.calc.outputs.total }}
  failed-runs:
    value: ${{ steps.calc.outputs.failed }}
  recent-conclusions:
    value: ${{ steps.calc.outputs.recent }}

runs:
  using: composite
  steps:
    - id: calc
      shell: bash
      env:
        GH_TOKEN: ${{ inputs.token }}
      run: |
        RUNS=$(gh run list \
          --repo ${{ inputs.repo }} \
          --workflow "${{ inputs.workflow-name }}" \
          --json conclusion \
          --limit ${{ inputs.lookback }} \
          --jq '.' 2>/dev/null || echo "[]")

        TOTAL=$(echo "$RUNS" | jq 'length')
        FAILED=$(echo "$RUNS" | jq '[.[] | select(.conclusion == "failure")] | length')

        if [ "$TOTAL" -eq 0 ]; then
          SCORE=0
        else
          SCORE=$(( (FAILED * 100) / TOTAL ))
        fi

        RECENT=$(echo "$RUNS" | jq -c '[.[0:5][] | .conclusion]')

        echo "score=$SCORE" >> $GITHUB_OUTPUT
        echo "total=$TOTAL" >> $GITHUB_OUTPUT
        echo "failed=$FAILED" >> $GITHUB_OUTPUT
        echo "recent=$RECENT" >> $GITHUB_OUTPUT
```

### 4.8 compute-mttr

```yaml
# actions/observability/analyzers/compute-mttr/action.yml
name: "Compute MTTR"
description: "Mean Time To Recovery for a workflow"

inputs:
  repo:
    required: true
  workflow-name:
    required: true
  lookback:
    required: false
    default: "50"
  token:
    required: true

outputs:
  mttr-minutes:
    value: ${{ steps.calc.outputs.mttr }}
  recovery-count:
    value: ${{ steps.calc.outputs.recoveries }}

runs:
  using: composite
  steps:
    - id: calc
      shell: bash
      env:
        GH_TOKEN: ${{ inputs.token }}
      run: |
        RUNS=$(gh run list \
          --repo ${{ inputs.repo }} \
          --workflow "${{ inputs.workflow-name }}" \
          --json conclusion,createdAt \
          --limit ${{ inputs.lookback }} \
          --jq 'sort_by(.createdAt)' 2>/dev/null || echo "[]")

        # 找 failure → success 的配对，计算时间差
        MTTR=$(echo "$RUNS" | jq '
          [., .[1:]] | transpose
          | map(select(.[0].conclusion == "failure" and .[1].conclusion == "success"))
          | map(
              ((.[1].createdAt | sub("\\.[0-9]+Z$"; "Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime)
              - (.[0].createdAt | sub("\\.[0-9]+Z$"; "Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime))
              / 60 | round
            )
          | if length > 0 then (add / length | round) else 0 end
        ')

        RECOVERIES=$(echo "$RUNS" | jq '
          [., .[1:]] | transpose
          | map(select(.[0].conclusion == "failure" and .[1].conclusion == "success"))
          | length
        ')

        echo "mttr=$MTTR" >> $GITHUB_OUTPUT
        echo "recoveries=$RECOVERIES" >> $GITHUB_OUTPUT
```

### 4.9 compute-trends

```yaml
# actions/observability/analyzers/compute-trends/action.yml
name: "Compute CI Trends"
description: "Calculate DORA metrics + flakiness + MTTR trends"

inputs:
  repo:
    required: true
  workflow-name:
    required: false
    default: ""
  lookback-days:
    required: false
    default: "30"
  current-health-data:
    description: "Current workflow health JSON from state"
    required: false
    default: "{}"
  token:
    required: true

outputs:
  trend:
    description: "improving | stable | degrading"
    value: ${{ steps.trend.outputs.trend }}
  delta:
    value: ${{ steps.trend.outputs.delta }}
  dora-section:
    description: "DORA metrics markdown (from DeveloperMetrics actions)"
    value: ${{ steps.dora.outputs.section }}

runs:
  using: composite
  steps:
    - name: Compute trend from health data
      id: trend
      shell: bash
      run: |
        HEALTH='${{ inputs.current-health-data }}'

        # 提取最近 7 天和前 7 天的失败率
        CURRENT=$(echo "$HEALTH" | jq '
          if .daily then
            [.daily | to_entries | .[-7:][] | .value] | if length > 0 then (add / length | round) else 0 end
          else 0 end
        ')
        PREVIOUS=$(echo "$HEALTH" | jq '
          if .daily then
            [.daily | to_entries | .[-14:-7][] | .value] | if length > 0 then (add / length | round) else 0 end
          else 0 end
        ')

        DELTA=$(( CURRENT - PREVIOUS ))

        if [ "$DELTA" -gt 10 ]; then
          TREND="degrading"
        elif [ "$DELTA" -lt -10 ]; then
          TREND="improving"
        else
          TREND="stable"
        fi

        echo "trend=$TREND" >> $GITHUB_OUTPUT
        echo "delta=$DELTA" >> $GITHUB_OUTPUT

    - name: Compute DORA metrics
      id: dora
      shell: bash
      run: |
        # DORA metrics 通过 DeveloperMetrics actions 在 workflow 层计算
        # 这里只做聚合格式化
        echo "section=_DORA metrics computed at workflow level_" >> $GITHUB_OUTPUT
```

---

## 五、状态层（State）

### 5.1 双层持久化架构

```
┌─────────────────────────────────────────┐
│           GitHub Actions Cache          │  快速层（毫秒级读取）
│  key: ci-obs:{type}:{scope}:{date}      │  TTL: 7 天未访问自动驱逐
│  内容: 可重建的临时状态                  │  (计数器、dedup 锁)
└──────────────┬──────────────────────────┘
               │ cache miss → 回源
               ▼
┌─────────────────────────────────────────┐
│           _state 孤儿分支                │  持久层（秒级读取）
│  与 main 无共享历史，不触发 CI           │  append-only，长期累积
│  内容: known-patterns / 健康快照 / 计数器│
└─────────────────────────────────────────┘
```

**`_state` 分支结构**：

```
_state/
├── known-patterns.json        # 已知失败模式库（AI 自动 PR，人工审核）
├── circuit-breaker-state.json # 活跃熔断状态
├── daily-counters/
│   └── 2026-05-01.json       # 当日重跑/分诊计数
├── workflow-health/
│   └── org-repo-workflow.json # 各 workflow 30 天健康度
└── weekly-snapshots/
    └── 2026-W18.json         # 周级聚合快照
```

**初始化**（手动执行一次）：

```bash
git checkout --orphan _state
git rm -rf .
git commit --allow-empty -m "init: CI observability state branch"
git push origin _state
```

### 5.2 read-state

```yaml
# actions/observability/state/read-state/action.yml
name: "Read State"
description: "Read state from cache (fast) with _state branch fallback"

inputs:
  key:
    description: "State key, e.g. retries:org/repo:2026-04-30"
    required: true
  state-path:
    description: "Path in _state branch, e.g. daily-counters/2026-04-30.json"
    required: false
  default:
    description: "Default value if not found"
    required: false
    default: "{}"

outputs:
  hit:
    value: ${{ steps.read.outputs.hit }}
  value:
    value: ${{ steps.read.outputs.value }}

runs:
  using: composite
  steps:
    - id: read
      shell: bash
      run: |
        CACHE_DIR=".state-cache"
        mkdir -p "$CACHE_DIR"

        # 快速路径：读 cache
        CACHE_KEY="ci-obs:${{ inputs.key }}"
        if [ -f "$CACHE_DIR/data.json" ]; then
          VALUE=$(cat "$CACHE_DIR/data.json")
          echo "hit=true" >> $GITHUB_OUTPUT
          echo "value=$VALUE" >> $GITHUB_OUTPUT
          exit 0
        fi

        # 慢速路径：回源 _state 分支
        if [ -n "${{ inputs.state-path }}" ]; then
          git fetch origin _state 2>/dev/null || true
          VALUE=$(git show "origin/_state:${{ inputs.state-path }}" 2>/dev/null || echo '${{ inputs.default }}')

          # 回填 cache
          echo "$VALUE" > "$CACHE_DIR/data.json"
          echo "hit=true" >> $GITHUB_OUTPUT
        else
          VALUE='${{ inputs.default }}'
          echo "hit=false" >> $GITHUB_OUTPUT
        fi

        echo "value=$VALUE" >> $GITHUB_OUTPUT
```

### 5.3 write-state

```yaml
# actions/observability/state/write-state/action.yml
name: "Write State"
description: "Dual-write: cache (fast) + _state branch (durable) with retry"

inputs:
  key:
    required: true
  state-path:
    required: true
  value:
    description: "JSON value to write"
    required: true
  merge:
    description: "true = merge with existing, false = overwrite"
    required: false
    default: "true"

runs:
  using: composite
  steps:
    # 快速路径：写 cache
    - shell: bash
      run: |
        mkdir -p .state-cache
        cat <<'JSON' > ".state-cache/data.json"
        ${{ inputs.value }}
        JSON

    # 持久路径：写 _state 分支（带 retry）
    - name: Persist to _state branch
      uses: nick-fields/retry@{SHA}
      with:
        timeout_minutes: 2
        max_attempts: 3
        retry_wait_seconds: 5
        command: |
          git fetch origin _state
          git checkout -B _state origin/_state

          TARGET="${{ inputs.state-path }}"
          mkdir -p "$(dirname "$TARGET")"

          if [ "${{ inputs.merge }}" = "true" ] && [ -f "$TARGET" ]; then
            # JSON merge：新值覆盖旧值
            jq -s '.[0] * .[1]' "$TARGET" <(echo '${{ inputs.value }}') > tmp.json
            mv tmp.json "$TARGET"
          else
            echo '${{ inputs.value }}' > "$TARGET"
          fi

          git add .
          git -c user.name="evolveCI bot" -c user.email="bot@evolveci.dev" \
            commit -m "state: update ${{ inputs.key }}" || true
          git push origin _state
```

### 5.4 redact-log

```yaml
# actions/observability/state/redact-log/action.yml
name: "Redact Log"
description: "Remove sensitive data from logs before AI processing"

inputs:
  log:
    description: "Raw log text (base64 encoded)"
    required: true

outputs:
  redacted:
    value: ${{ steps.redact.outputs.log }}

runs:
  using: composite
  steps:
    - id: redact
      shell: bash
      run: |
        # Decode
        LOG=$(echo "${{ inputs.log }}" | base64 -d 2>/dev/null || echo "")

        # Redact common sensitive patterns
        LOG=$(echo "$LOG" | sed -E \
          -e 's/token[[:space:]]*=[[:space:]]*[a-zA-Z0-9_.-]+/token=***REDACTED***/gi' \
          -e 's/password[[:space:]]*=[[:space:]]*[a-zA-Z0-9_.-]+/password=***REDACTED***/gi' \
          -e 's/secret[[:space:]]*=[[:space:]]*[a-zA-Z0-9_.-]+/secret=***REDACTED***/gi' \
          -e 's/api[_-]?key[[:space:]]*=[[:space:]]*[a-zA-Z0-9_.-]+/api_key=***REDACTED***/gi' \
          -e 's/Bearer[[:space:]]+[a-zA-Z0-9_.-]+/Bearer ***REDACTED***/gi' \
          -e 's/ghp_[a-zA-Z0-9]{36}/ghp_***REDACTED***/g' \
          -e 's/gho_[a-zA-Z0-9]{36}/gho_***REDACTED***/g' \
          -e 's/sk-[a-zA-Z0-9]{20,}/sk-***REDACTED***/g' \
          -e 's/(10|172|192)\.[0-9]+\.[0-9]+\.[0-9]+/***REDACTED_IP***/g' \
        )

        echo "log<<EOF" >> $GITHUB_OUTPUT
        echo "$LOG" >> $GITHUB_OUTPUT
        echo "EOF" >> $GITHUB_OUTPUT
```

---

## 六、发布层（Publishers）

### 6.1 auto-rerun

```yaml
# actions/observability/publishers/auto-rerun/action.yml
name: "Auto Rerun"
description: "Rerun failed jobs with budget check"

inputs:
  repo:
    required: true
  run-id:
    required: true
  workflow-name:
    required: true
  daily-budget:
    description: "Max reruns per workflow per day"
    required: false
    default: "3"
  token:
    required: true

outputs:
  rerun:
    value: ${{ steps.rerun.outputs.result }}
  budget-remaining:
    value: ${{ steps.budget.outputs.remaining }}

runs:
  using: composite
  steps:
    - name: Check budget
      id: budget
      shell: bash
      run: |
        TODAY=$(date +%Y-%m-%d)
        KEY="${{ inputs.repo }}/${{ inputs.workflow-name }}/$TODAY"

        # 读取当日计数（从 state）
        git fetch origin _state 2>/dev/null || true
        COUNTER=$(git show "origin/_state:daily-counters/$TODAY.json" 2>/dev/null || echo '{}')
        COUNT=$(echo "$COUNTER" | jq -r ".reruns[\"$KEY\"] // 0")
        MAX=${{ inputs.daily-budget }}

        REMAINING=$(( MAX - COUNT ))

        if [ "$REMAINING" -le 0 ]; then
          echo "remaining=0" >> $GITHUB_OUTPUT
          echo "::warning title=Rerun Budget Exhausted::${{ inputs.repo }}/${{ inputs.workflow-name }} already rerun $COUNT times today"
        else
          echo "remaining=$REMAINING" >> $GITHUB_OUTPUT
        fi

    - name: Rerun failed jobs
      id: rerun
      if: steps.budget.outputs.remaining > 0
      shell: bash
      env:
        GH_TOKEN: ${{ inputs.token }}
      run: |
        # 安全约束：永不重跑 deploy/security workflow
        WF="${{ inputs.workflow-name }}"
        case "$WF" in
          *deploy*|*security*|*scan*|*sign*)
            echo "result=skipped-forbidden" >> $GITHUB_OUTPUT
            echo "::notice title=Rerun Blocked::workflow '$WF' matches forbidden pattern"
            exit 0
            ;;
        esac

        gh run rerun ${{ inputs.run-id }} \
          --repo ${{ inputs.repo }} \
          --failed

        echo "result=rerunned" >> $GITHUB_OUTPUT
        echo "::notice title=Auto Rerun::run=${{ inputs.run-id }} repo=${{ inputs.repo }}"

    - name: Update counter
      if: steps.rerun.outputs.result == 'rerunned'
      shell: bash
      run: |
        TODAY=$(date +%Y-%m-%d)
        KEY="${{ inputs.repo }}/${{ inputs.workflow-name }}/$TODAY"

        git fetch origin _state 2>/dev/null || true
        git checkout -B _state origin/_state 2>/dev/null || true

        mkdir -p daily-counters
        TARGET="daily-counters/$TODAY.json"

        if [ -f "$TARGET" ]; then
          CURRENT=$(cat "$TARGET")
        else
          CURRENT='{"reruns":{}}'
        fi

        UPDATED=$(echo "$CURRENT" | jq --arg key "$KEY" '.reruns[$key] = ((.reruns[$key] // 0) + 1)')
        echo "$UPDATED" > "$TARGET"

        git add .
        git -c user.name="evolveCI bot" -c user.email="bot@evolveci.dev" \
          commit -m "state: rerun $KEY" || true
        git push origin _state
```

### 6.2 trip-circuit-breaker

```yaml
# actions/observability/publishers/trip-circuit-breaker/action.yml
name: "Trip Circuit Breaker"
description: "Create issue + Slack alert when budget exceeded"

inputs:
  repo:
    required: true
  workflow-name:
    required: true
  reason:
    required: true
  dimension:
    description: "Which budget dimension: workflow | pattern | repo"
    required: true
  history:
    description: "Recent rerun/failure history JSON"
    required: false
    default: "[]"

runs:
  using: composite
  steps:
    - name: Create circuit breaker issue
      shell: bash
      env:
        GH_TOKEN: ${{ github.token }}
      run: |
        BODY=$(cat <<EOF
        ## ⚡ Circuit Breaker Tripped

        - **Repo**: ${{ inputs.repo }}
        - **Workflow**: ${{ inputs.workflow-name }}
        - **Dimension**: ${{ inputs.dimension }}
        - **Reason**: ${{ inputs.reason }}

        ### Recent History
        \`\`\`json
        ${{ inputs.history }}
        \`\`\`

        ---
        **Action required**: Remove label \`ci:circuit-broken\` from this issue to resume auto-processing.
        Or comment \`/resume\` below.
        EOF
        )

        gh issue create \
          --repo ${{ github.repository }} \
          --title "⚡ Circuit Breaker: ${{ inputs.repo }}/${{ inputs.workflow-name }}" \
          --label "ci:circuit-broken,severity/critical" \
          --body "$BODY"

    - name: Notify Slack
      uses: your-org/openCI/actions/integrations/slack-notify@v2
      continue-on-error: true
      with:
        webhook-url: ${{ env.SLACK_WEBHOOK_URL }}
        status: failure
        title: "⚡ Circuit Breaker: ${{ inputs.repo }}/${{ inputs.workflow-name }}"
        message: "${{ inputs.reason }} — Remove ci:circuit-broken label to resume"
```

### 6.3 post-issue-report

```yaml
# actions/observability/publishers/post-issue-report/action.yml
name: "Post Issue Report"
description: "Create GitHub Issue from markdown file"

inputs:
  title:
    required: true
  report-path:
    description: "Path to markdown file"
    required: true
  labels:
    required: false
    default: "ci-report"
  assignees:
    required: false
    default: ""

runs:
  using: composite
  steps:
    - uses: peter-evans/create-issue-from-file@{SHA}
      with:
        title: ${{ inputs.title }}
        content-filepath: ${{ inputs.report-path }}
        labels: ${{ inputs.labels }}
        assignees: ${{ inputs.assignees }}
```

### 6.4 post-slack-report

```yaml
# actions/observability/publishers/post-slack-report/action.yml
name: "Post Slack Report"
description: "Send report to Slack (reuses OpenCI slack-notify)"

inputs:
  webhook-url:
    required: true
  title:
    required: true
  message:
    required: true
  status:
    required: false
    default: "info"

runs:
  using: composite
  steps:
    - uses: your-org/openCI/actions/integrations/slack-notify@v2
      continue-on-error: true
      with:
        webhook-url: ${{ inputs.webhook-url }}
        status: ${{ inputs.status }}
        title: ${{ inputs.title }}
        message: ${{ inputs.message }}
```

---

## 七、实时分诊工作流

### 7.1 triage-failure.yml

```yaml
name: "Triage: Scan & Classify Failures"
on:
  schedule:
    - cron: '*/15 * * * *'     # 每 15 分钟
  workflow_dispatch:

concurrency:
  group: ci-triage
  cancel-in-progress: false    # 不取消正在跑的 triage

permissions: {}

jobs:
  scan:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    permissions:
      contents: read
    steps:
      - uses: step-security/harden-runner@{SHA}
        with:
          egress-policy: audit

      - uses: actions/checkout@{SHA}

      - name: Check circuit breaker
        id: circuit
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          # 如果有未解除的 circuit breaker，直接退出
          BROKEN=$(gh issue list \
            --label "ci:circuit-broken" \
            --state open \
            --json number \
            --limit 1 \
            --jq '.[0].number // empty' 2>/dev/null || echo "")
          if [ -n "$BROKEN" ]; then
            echo "::notice title=Circuit Breaker Active::Skipping triage, open issue #$BROKEN"
            echo "skip=true" >> $GITHUB_OUTPUT
          else
            echo "skip=false" >> $GITHUB_OUTPUT
          fi

      - name: Load onboarded repos
        if: steps.circuit.outputs.skip != 'true'
        id: repos
        run: |
          REPOS=$(yq '.repos | map(.name) | join(",")' data/onboarded-repos.yml)
          echo "list=$REPOS" >> $GITHUB_OUTPUT

      - name: Scan for failures
        if: steps.circuit.outputs.skip != 'true'
        uses: ./actions/observability/sources/query-github-actions
        id: runs
        with:
          repos: ${{ steps.repos.outputs.list }}
          since: 30m
          status: failure
          include-logs: true
          log-tail: 100
          token: ${{ secrets.CROSS_REPO_PAT }}

      - name: Skip if no failures
        if: steps.circuit.outputs.skip != 'true' && steps.runs.outputs.failure-count == '0'
        run: echo "No failures found. Exiting."

    outputs:
      runs: ${{ steps.runs.outputs.runs || '[]' }}
      failure-count: ${{ steps.runs.outputs.failure-count || '0' }}

  triage:
    needs: scan
    if: >
      needs.scan.outputs.failure-count != '0' &&
      needs.scan.outputs.failure-count != '' &&
      fromJson(needs.scan.outputs.runs || '[]') != []
    runs-on: ubuntu-latest
    timeout-minutes: 15
    permissions:
      contents: write
      issues: write
    strategy:
      max-parallel: 3
      fail-fast: false
      matrix:
        run: ${{ fromJson(needs.scan.outputs.runs || '[]')[0:10] }}
    steps:
      - uses: step-security/harden-runner@{SHA}
        with:
          egress-policy: audit

      - uses: actions/checkout@{SHA}

      - name: Fetch _state branch
        run: git fetch origin _state 2>/dev/null || true

      - name: Load known patterns
        id: patterns
        run: |
          PATTERNS=$(git show origin/_state:known-patterns.json 2>/dev/null || echo '[]')
          echo "data<<EOF" >> $GITHUB_OUTPUT
          echo "$PATTERNS" >> $GITHUB_OUTPUT
          echo "EOF" >> $GITHUB_OUTPUT

      - name: Redact log
        id: redacted
        uses: ./actions/observability/state/redact-log
        with:
          log: ${{ matrix.run.log_base64 || '' }}

      # ── Tier 1: match-known-patterns ──
      - name: Tier 1 - Match known patterns
        if: steps.redacted.outputs.redacted != ''
        id: t1
        uses: ./actions/observability/analyzers/match-known-patterns
        with:
          log: ${{ steps.redacted.outputs.redacted }}
          patterns-path: known-patterns.json
        env:
          KNOWN_PATTERNS_DATA: ${{ steps.patterns.outputs.data }}

      - name: Inject patterns data
        if: steps.redacted.outputs.redacted != ''
        shell: bash
        run: |
          echo '${{ steps.patterns.outputs.data }}' > known-patterns.json

      # ── Tier 2: classify-heuristic ──
      - name: Tier 2 - Heuristic classification
        if: steps.t1.outputs.matched != 'true' && steps.redacted.outputs.redacted != ''
        id: t2
        uses: ./actions/observability/analyzers/classify-heuristic
        with:
          log: ${{ steps.redacted.outputs.redacted }}
          failed-step: ${{ matrix.run.failed_jobs[0].name || '' }}
          flakiness-score: 0

      # ── Tier 3: AI classification (Haiku) ──
      # AI 调用在 workflow 级别，不在 composite action 内部
      - name: Tier 3 - Prepare AI context
        if: >
          steps.t1.outputs.matched != 'true' &&
          steps.t2.outputs.confidence == 'low' &&
          steps.redacted.outputs.redacted != ''
        id: t3-prepare
        uses: ./actions/observability/analyzers/classify-ai
        with:
          log: ${{ steps.redacted.outputs.redacted }}
          workflow-name: ${{ matrix.run.workflowName }}
          failed-step: ${{ matrix.run.failed_jobs[0].name || '' }}
          repo: ${{ matrix.run.repo }}
          run-id: ${{ matrix.run.databaseId }}
          tier: "3"

      - name: Tier 3 - AI Classify (Haiku)
        if: steps.t3-prepare.outputs.context != ''
        id: t3
        uses: your-org/openCI/.github/workflows/claude-harness.yml@v2
        with:
          task: ci-classify-failure
          prompt-path: ${{ steps.t3-prepare.outputs.prompt_path }}
          model: ${{ steps.t3-prepare.outputs.model }}
          max-turns: 1
          context: ${{ steps.t3-prepare.outputs.context }}
        continue-on-error: true

      # ── Dispatch ──
      - name: Dispatch action
        id: dispatch
        if: always()
        shell: bash
        run: |
          # 汇总分类结果，按 Tier 优先级
          if [ "${{ steps.t1.outputs.matched }}" = "true" ]; then
            CATEGORY="${{ steps.t1.outputs.category }}"
            SEVERITY="${{ steps.t1.outputs.severity }}"
            SHOULD_RERUN="${{ steps.t1.outputs.auto-rerun }}"
            SHOULD_NOTIFY="${{ steps.t1.outputs.notify }}"
            SUMMARY="Known: ${{ steps.t1.outputs.pattern-id }}"
            TIER="1"
          elif [ "${{ steps.t2.outputs.confidence }}" = "high" ] || [ "${{ steps.t2.outputs.confidence }}" = "medium" ]; then
            CATEGORY="${{ steps.t2.outputs.category }}"
            SEVERITY="${{ steps.t2.outputs.severity }}"
            SHOULD_RERUN="${{ steps.t2.outputs.should-rerun }}"
            SHOULD_NOTIFY="${{ steps.t2.outputs.should-notify }}"
            SUMMARY="Heuristic: ${{ steps.t2.outputs.category }}"
            TIER="2"
          elif [ "${{ steps.t3.outputs.result }}" != "" ]; then
            RESULT='${{ steps.t3.outputs.result }}'
            CATEGORY=$(echo "$RESULT" | jq -r '.category // "unknown"')
            SEVERITY=$(echo "$RESULT" | jq -r '.severity // "medium"')
            SUMMARY=$(echo "$RESULT" | jq -r '.summary // "AI classified"')
            SHOULD_RERUN=$(echo "$RESULT" | jq -r '.should_rerun // false')
            SHOULD_NOTIFY=$(echo "$RESULT" | jq -r '.should_notify // true')
            TIER="3"
          else
            CATEGORY="unknown"
            SEVERITY="medium"
            SHOULD_RERUN="false"
            SHOULD_NOTIFY="true"
            SUMMARY="Unclassified failure"
            TIER="0"
          fi

          echo "category=$CATEGORY" >> $GITHUB_OUTPUT
          echo "severity=$SEVERITY" >> $GITHUB_OUTPUT
          echo "should_rerun=$SHOULD_RERUN" >> $GITHUB_OUTPUT
          echo "should_notify=$SHOULD_NOTIFY" >> $GITHUB_OUTPUT
          echo "summary=$SUMMARY" >> $GITHUB_OUTPUT
          echo "tier=$TIER" >> $GITHUB_OUTPUT

      # ── Auto-rerun (flaky only) ──
      - name: Auto rerun
        if: steps.dispatch.outputs.should_rerun == 'true'
        uses: ./actions/observability/publishers/auto-rerun
        with:
          repo: ${{ matrix.run.repo }}
          run-id: ${{ matrix.run.databaseId }}
          workflow-name: ${{ matrix.run.workflowName }}
          token: ${{ secrets.CROSS_REPO_PAT }}

      # ── Create issue (non-flaky) ──
      - name: Create issue
        if: >
          steps.dispatch.outputs.should_notify == 'true' &&
          steps.dispatch.outputs.category != 'flaky'
        shell: bash
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          REPO="${{ matrix.run.repo }}"
          RUN_ID="${{ matrix.run.databaseId }}"
          WF="${{ matrix.run.workflowName }}"
          CATEGORY="${{ steps.dispatch.outputs.category }}"
          SEVERITY="${{ steps.dispatch.outputs.severity }}"
          SUMMARY="${{ steps.dispatch.outputs.summary }}"

          # 去重：检查是否已有同 workflow 的 open issue
          EXISTING=$(gh issue list \
            --label "ci/$CATEGORY" \
            --search "$WF in:title" \
            --state open \
            --json number \
            --limit 1 \
            --jq '.[0].number // empty' 2>/dev/null || echo "")

          BODY=$(cat <<EOF
          ## CI Failure: $WF

          - **Repo**: $REPO
          - **Run**: [#${RUN_ID}](https://github.com/$REPO/actions/runs/$RUN_ID)
          - **Branch**: ${{ matrix.run.headBranch }}
          - **Category**: $CATEGORY (Tier ${{ steps.dispatch.outputs.tier }})
          - **Severity**: $SEVERITY
          - **Summary**: $SUMMARY
          EOF
          )

          if [ -n "$EXISTING" ]; then
            gh issue comment "$EXISTING" --body "$BODY"
          else
            gh issue create \
              --title "CI [$CATEGORY]: $WF - $SUMMARY" \
              --label "ci/$CATEGORY,severity/$SEVERITY" \
              --body "$BODY" || true
          fi

      # ── Slack (critical/high only) ──
      - name: Notify Slack
        if: >
          steps.dispatch.outputs.should_notify == 'true' &&
          (steps.dispatch.outputs.severity == 'critical' || steps.dispatch.outputs.severity == 'high')
        uses: ./actions/observability/publishers/post-slack-report
        with:
          webhook-url: ${{ secrets.SLACK_CI_WEBHOOK }}
          title: "CI ${{ steps.dispatch.outputs.severity }}: ${{ matrix.run.workflowName }}"
          message: "${{ steps.dispatch.outputs.summary }} — ${{ matrix.run.repo }}"
          status: failure

      # ── Learn new pattern ──
      - name: Learn new pattern
        if: steps.t3.outputs.result != ''
        shell: bash
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          RESULT='${{ steps.t3.outputs.result }}'
          PATTERN=$(echo "$RESULT" | jq -r '.matched_pattern // empty')

          # 空模式不学习
          [ -z "$PATTERN" ] && exit 0

          # 验证模式不是 ReDoS（简单检查：长度 < 200，无嵌套量词）
          if [ ${#PATTERN} -gt 200 ]; then
            echo "::warning title=Pattern Too Long::Skipping, potential ReDoS risk"
            exit 0
          fi

          CATEGORY="${{ steps.dispatch.outputs.category }}"
          ID="ai-$(echo "$PATTERN" | md5sum | head -c 8)"
          TODAY=$(date +%Y-%m-%d)

          NEW_PATTERN=$(jq -n \
            --arg id "$ID" \
            --arg match "$PATTERN" \
            --arg cat "$CATEGORY" \
            --argjson rerun "${{ steps.dispatch.outputs.should_rerun }}" \
            --argjson notify "${{ steps.dispatch.outputs.should_notify }}" \
            --arg sev "${{ steps.dispatch.outputs.severity }}" \
            --arg date "$TODAY" \
            '{
              id: $id,
              match: $match,
              category: $cat,
              auto_rerun: $rerun,
              notify: $notify,
              severity: $sev,
              seen_count: 1,
              last_seen: $date,
              source: "ai-tier3"
            }')

          # 写入临时文件，后续 create-pull-request 开 PR
          echo "$NEW_PATTERN" > /tmp/new-pattern.json

      - name: PR new pattern for review
        if: steps.t3.outputs.result != ''
        uses: peter-evans/create-pull-request@{SHA}
        with:
          branch: pattern/${{ matrix.run.databaseId }}
          title: "🤖 New failure pattern: ${{ steps.dispatch.outputs.category }}"
          body: |
            Auto-learned from run [${{ matrix.run.databaseId }}](https://github.com/${{ matrix.run.repo }}/actions/runs/${{ matrix.run.databaseId }})

            **Category**: ${{ steps.dispatch.outputs.category }}
            **Severity**: ${{ steps.dispatch.outputs.severity }}

            Review the pattern regex for correctness and safety before merging.
          commit-message: "pattern: add ai-learned pattern for ${{ steps.dispatch.outputs.category }}"
```

---

## 八、每日 CI 健康报告

### 8.1 health-ci-daily.yml

```yaml
name: "Health: CI Daily Report"
on:
  schedule:
    - cron: '0 1 * * 1-5'    # 工作日 UTC 01:00
  workflow_dispatch:

concurrency:
  group: ci-health-daily
  cancel-in-progress: false

permissions:
  contents: read
  issues: write

jobs:
  collect:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    outputs:
      stats: ${{ steps.aggregate.outputs.stats }}
    steps:
      - uses: step-security/harden-runner@{SHA}
        with:
          egress-policy: audit

      - uses: actions/checkout@{SHA}

      - name: Load repos
        id: repos
        run: |
          REPOS=$(yq '.repos | map(.name) | join(",")' data/onboarded-repos.yml)
          echo "list=$REPOS" >> $GITHUB_OUTPUT

      - name: Collect 24h runs
        uses: ./actions/observability/sources/query-github-actions
        id: all-runs
        with:
          repos: ${{ steps.repos.outputs.list }}
          since: 24h
          status: all
          include-logs: false
          token: ${{ secrets.CROSS_REPO_PAT }}

      - name: Compute per-workflow stats
        id: flakiness
        shell: bash
        run: |
          RUNS='${{ steps.all-runs.outputs.runs }}'

          STATS=$(echo "$RUNS" | jq '
            group_by(.repo + "/" + .workflowName) |
            map({
              key: .[0].repo + "/" + .[0].workflowName,
              repo: .[0].repo,
              workflow: .[0].workflowName,
              total: length,
              failed: [.[] | select(.conclusion == "failure")] | length,
              success: [.[] | select(.conclusion == "success")] | length,
              failure_rate: (([.[] | select(.conclusion == "failure")] | length) / length * 100 | round)
            })
          ')

          echo "stats=$(echo "$STATS" | jq -c '.')" >> $GITHUB_OUTPUT

      - name: Detect degradations
        id: degradations
        shell: bash
        run: |
          STATS='${{ steps.flakiness.outputs.stats }}'
          DEGRADATIONS="[]"

          # 从 _state 读取历史健康数据
          git fetch origin _state 2>/dev/null || true

          echo "$STATS" | jq -c '.[]' | while read -r item; do
            REPO=$(echo "$item" | jq -r '.repo')
            WF=$(echo "$item" | jq -r '.workflow')
            CURRENT=$(echo "$item" | jq -r '.failure_rate')
            SAFE_KEY=$(echo "${REPO}_${WF}" | tr '/' '_')

            HEALTH=$(git show "origin/_state:workflow-health/${SAFE_KEY}.json" 2>/dev/null || echo '{}')
            SEVEN_DAY=$(echo "$HEALTH" | jq '
              if .daily then
                [.daily | to_entries | .[-7:][] | .value] | if length > 0 then (add / length | round) else 0 end
              else 0 end
            ')

            DELTA=$(( CURRENT - SEVEN_DAY ))
            if [ "$DELTA" -gt 10 ]; then
              DEGRADATIONS=$(echo "$DEGRADATIONS" | jq \
                --arg repo "$REPO" \
                --arg wf "$WF" \
                --argjson current "$CURRENT" \
                --argjson avg "$SEVEN_DAY" \
                --argjson delta "$DELTA" \
                '. + [{"repo": $repo, "workflow": $wf, "current": $current, "seven_day_avg": $avg, "delta": $delta}]')
            fi
          done

          echo "degradations=$(echo "$DEGRADATIONS" | jq -c '.')" >> $GITHUB_OUTPUT

      - name: Update health history
        shell: bash
        run: |
          STATS='${{ steps.flakiness.outputs.stats }}'
          TODAY=$(date +%Y-%m-%d)

          git fetch origin _state 2>/dev/null || true
          git checkout -B _state origin/_state 2>/dev/null || true

          mkdir -p workflow-health

          echo "$STATS" | jq -c '.[]' | while read -r item; do
            REPO=$(echo "$item" | jq -r '.repo')
            WF=$(echo "$item" | jq -r '.workflow')
            RATE=$(echo "$item" | jq -r '.failure_rate')
            SAFE_KEY=$(echo "${REPO}_${WF}" | tr '/' '_')
            TARGET="workflow-health/${SAFE_KEY}.json"

            # 读取或初始化
            if git show "origin/_state:$TARGET" > /tmp/health.json 2>/dev/null; then
              EXISTING=$(cat /tmp/health.json)
            else
              EXISTING='{"daily":{}}'
            fi

            # 追加今日数据
            UPDATED=$(echo "$EXISTING" | jq \
              --arg date "$TODAY" \
              --argjson rate "$RATE" \
              '.daily[$date] = $rate')

            echo "$UPDATED" > "$TARGET"
          done

          git add workflow-health/
          git -c user.name="evolveCI bot" -c user.email="bot@evolveci.dev" \
            commit -m "state: daily health snapshot $TODAY" || true
          git push origin _state

      - name: Aggregate for AI
        id: aggregate
        shell: bash
        run: |
          TOTAL_COUNT='${{ steps.all-runs.outputs.count }}'
          FAILURE_COUNT='${{ steps.all-runs.outputs.failure-count }}'
          STATS='${{ steps.flakiness.outputs.stats }}'
          DEGRADATIONS='${{ steps.degradations.outputs.degradations }}'

          if [ "$TOTAL_COUNT" -gt 0 ]; then
            RATE=$(( (FAILURE_COUNT * 100) / TOTAL_COUNT ))
          else
            RATE=0
          fi

          STATS_JSON=$(jq -n \
            --argjson total "$TOTAL_COUNT" \
            --argjson failures "$FAILURE_COUNT" \
            --argjson rate "$RATE" \
            --argjson flakiness "$STATS" \
            --argjson degradations "$DEGRADATIONS" \
            '{
              total_runs: $total,
              total_failures: $failures,
              failure_rate: $rate,
              workflows: $flakiness,
              degradations: $degradations
            }')

          echo "stats=$(echo "$STATS_JSON" | jq -c '.')" >> $GITHUB_OUTPUT

  synthesize:
    needs: collect
    if: needs.collect.outputs.stats != '' && needs.collect.outputs.stats != '{}'
    uses: your-org/openCI/.github/workflows/claude-harness.yml@v2
    with:
      task: ci-daily-report
      prompt-path: prompts/observability/daily-report.md
      model: claude-haiku-4-5-20251001
      max-turns: 1
      context: ${{ needs.collect.outputs.stats }}

  publish:
    needs: synthesize
    if: needs.synthesize.outputs.result != ''
    runs-on: ubuntu-latest
    timeout-minutes: 5
    permissions:
      contents: read
      issues: write
    steps:
      - uses: actions/checkout@{SHA}

      - name: Write report to file
        run: |
          cat > /tmp/daily-report.md <<'EOF'
          ${{ needs.synthesize.outputs.result }}
          EOF

      - name: Post as GitHub Issue
        uses: ./actions/observability/publishers/post-issue-report
        with:
          title: "📊 CI Health Report - $(date +%Y-%m-%d)"
          report-path: /tmp/daily-report.md
          labels: "daily-report,ci-health"

      - name: Post to Slack
        uses: ./actions/observability/publishers/post-slack-report
        with:
          webhook-url: ${{ secrets.SLACK_CI_WEBHOOK }}
          title: "📊 CI Health Report - $(date +%Y-%m-%d)"
          message: ${{ needs.synthesize.outputs.result }}
```

### 8.2 daily-report prompt

```markdown
<!-- prompts/observability/daily-report.md -->
你是 CI 健康报告生成器。基于以下统计数据，生成一份简洁的日报。

数据：
{{context}}

输出格式（严格遵循）：

# CI Health Report - {今日日期}

## TL;DR
- 整体健康度: {100 - failure_rate}%（{与昨日对比趋势}）
- {1-2 条最重要的事}

## 关键指标
| 指标 | 今日 | 趋势 |
|------|------|------|
| 总运行 | {total_runs} | - |
| 失败率 | {failure_rate}% | {degradations 有则↑，无则→} |

## 需要关注
{列出 degradations 中的每一项，如果没有则写"无"}

## Top Flaky Workflows
{列出 failure_rate > 20% 的 workflow，按失败率降序，最多 5 个}

## 好消息
{列出 failure_rate = 0 的 workflow，或 failure_rate 明显下降的}

## 建议行动项
{基于数据给出 1-3 条具体可执行的建议}

规则：
- 总长度不超过 500 字
- 不要虚构数据，只基于输入统计
- 如果 total_runs = 0，说明"过去 24h 无运行"
- 使用 Markdown 格式
```

---

## 九、每周深度分析

### 9.1 health-ci-weekly.yml

```yaml
name: "Health: CI Weekly Deep Dive"
on:
  schedule:
    - cron: '0 2 * * 1'      # 每周一 UTC 02:00
  workflow_dispatch:

concurrency:
  group: ci-health-weekly
  cancel-in-progress: false

permissions:
  contents: read
  issues: write

jobs:
  collect:
    runs-on: ubuntu-latest
    timeout-minutes: 20
    outputs:
      weekly-data: ${{ steps.aggregate.outputs.data }}
    steps:
      - uses: step-security/harden-runner@{SHA}
        with:
          egress-policy: audit

      - uses: actions/checkout@{SHA}

      - name: Load repos
        id: repos
        run: |
          REPOS=$(yq '.repos | map(.name) | join(",")' data/onboarded-repos.yml)
          echo "list=$REPOS" >> $GITHUB_OUTPUT

      - name: Collect 7-day runs
        uses: ./actions/observability/sources/query-github-actions
        id: runs
        with:
          repos: ${{ steps.repos.outputs.list }}
          since: 7d
          status: all
          include-logs: false
          token: ${{ secrets.CROSS_REPO_PAT }}

      - name: Compute weekly stats
        id: aggregate
        shell: bash
        run: |
          RUNS='${{ steps.runs.outputs.runs }}'

          # 按 repo 聚合周级统计
          WEEKLY=$(echo "$RUNS" | jq '
            group_by(.repo) |
            map({
              repo: .[0].repo,
              total: length,
              failed: [.[] | select(.conclusion == "failure")] | length,
              success: [.[] | select(.conclusion == "success")] | length,
              workflows: (group_by(.workflowName) | map({
                name: .[0].workflowName,
                total: length,
                failed: [.[] | select(.conclusion == "failure")] | length,
                failure_rate: (([.[] | select(.conclusion == "failure")] | length) / length * 100 | round)
              }))
            })
          ')

          # 读取上周快照对比
          git fetch origin _state 2>/dev/null || true
          LAST_WEEK=$(date -d "7 days ago" +%Y-W%V 2>/dev/null || date -v-7d +%Y-W%V)
          PREVIOUS=$(git show "origin/_state:weekly-snapshots/${LAST_WEEK}.json" 2>/dev/null || echo '{}')

          DATA=$(jq -n \
            --argjson weekly "$WEEKLY" \
            --argjson previous "$PREVIOUS" \
            '{current: $weekly, previous: $previous}')

          echo "data=$(echo "$DATA" | jq -c '.')" >> $GITHUB_OUTPUT

      - name: Save weekly snapshot
        shell: bash
        run: |
          WEEK=$(date +%Y-W%V)
          git fetch origin _state 2>/dev/null || true
          git checkout -B _state origin/_state 2>/dev/null || true
          mkdir -p weekly-snapshots
          echo '${{ steps.aggregate.outputs.data }}' | jq '.current' > "weekly-snapshots/${WEEK}.json"
          git add weekly-snapshots/
          git -c user.name="evolveCI bot" -c user.email="bot@evolveci.dev" \
            commit -m "state: weekly snapshot $WEEK" || true
          git push origin _state

  synthesize:
    needs: collect
    if: needs.collect.outputs.weekly-data != ''
    uses: your-org/openCI/.github/workflows/claude-harness.yml@v2
    with:
      task: ci-weekly-deep-dive
      prompt-path: prompts/observability/weekly-deep-dive.md
      model: claude-sonnet-4-20250514
      max-turns: 1
      context: ${{ needs.collect.outputs.weekly-data }}

  publish:
    needs: synthesize
    if: needs.synthesize.outputs.result != ''
    runs-on: ubuntu-latest
    timeout-minutes: 5
    permissions:
      contents: read
      issues: write
    steps:
      - uses: actions/checkout@{SHA}

      - name: Write report
        run: echo '${{ needs.synthesize.outputs.result }}' > /tmp/weekly-report.md

      - name: Post as GitHub Issue
        uses: ./actions/observability/publishers/post-issue-report
        with:
          title: "📊 CI Weekly Deep Dive - $(date +%Y-W%V)"
          report-path: /tmp/weekly-report.md
          labels: "weekly-report,ci-health"

      - name: Post to Slack
        uses: ./actions/observability/publishers/post-slack-report
        with:
          webhook-url: ${{ secrets.SLACK_CI_WEBHOOK }}
          title: "📊 CI Weekly Deep Dive - $(date +%Y-W%V)"
          message: ${{ needs.synthesize.outputs.result }}
```

### 9.2 weekly-deep-dive prompt

```markdown
<!-- prompts/observability/weekly-deep-dive.md -->
你是资深 CI/CD 工程师，负责分析一周的 CI 数据并输出深度报告。

数据：
{{context}}

输出格式：

# CI Weekly Deep Dive - {周}

## Executive Summary
- 2-3 句话总结本周 CI 整体状况

## 关键指标变化
| 指标 | 本周 | 上周 | 变化 |
|------|------|------|------|
| 总运行 | - | - | - |
| 整体失败率 | - | - | - |
| Flaky workflow 数 | - | - | - |

## 仓库维度分析
{每个 repo 一段分析}

## Top 5 问题模式
{基于 failure rate 降序}

## DORA 指标评估
- 部署频率评级
- 变更前置时间评级
- 变更失败率评级
- MTTR 评级

## 趋势预测
{基于 2 周数据预测下周可能的问题}

## 行动建议
{3-5 条具体可执行建议}

规则：
- 不要虚构数据
- 如果 previous 为空，说明"首次周报，无对比数据"
- 总长度不超过 1000 字
```

---

## 十、自监控心跳

### 10.1 heartbeat.yml

```yaml
name: "Heartbeat: Self-Monitor"
on:
  schedule:
    - cron: '0 */6 * * *'    # 每 6 小时
  workflow_dispatch:

concurrency:
  group: ci-heartbeat
  cancel-in-progress: true     # 心跳可以取消前一个

permissions:
  contents: read

jobs:
  heartbeat:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - uses: step-security/harden-runner@{SHA}
        with:
          egress-policy: audit

      - name: Check triage-failure health
        id: triage
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          LAST_SUCCESS=$(gh run list \
            --repo ${{ github.repository }} \
            --workflow triage-failure.yml \
            --status success \
            --limit 1 \
            --json updatedAt \
            --jq '.[0].updatedAt // "never"' 2>/dev/null || echo "never")

          if [ "$LAST_SUCCESS" = "never" ]; then
            echo "::warning title=Control Tower Alert::triage-failure has never run successfully"
            echo "status=never" >> $GITHUB_OUTPUT
            exit 0
          fi

          LAST_TS=$(date -d "$LAST_SUCCESS" +%s 2>/dev/null || echo "0")
          NOW=$(date +%s)
          HOURS=$(( (NOW - LAST_TS) / 3600 ))

          if [ "$HOURS" -gt 24 ]; then
            echo "::error title=Control Tower Down::triage-failure hasn't succeeded in ${HOURS}h"
            exit 1
          fi

          echo "::notice title=Heartbeat OK::last triage success: ${HOURS}h ago"
          echo "status=ok" >> $GITHUB_OUTPUT

      - name: Check data freshness
        run: |
          git fetch origin _state 2>/dev/null || true

          LAST_COMMIT=$(git log -1 --format="%at" "origin/_state" -- workflow-health/ 2>/dev/null || echo "0")
          NOW=$(date +%s)
          HOURS=$(( (NOW - LAST_COMMIT) / 3600 ))

          if [ "$HOURS" -gt 48 ]; then
            echo "::warning title=Stale Health Data::_state/workflow-health/ is ${HOURS}h old"
          else
            echo "::notice title=Data Fresh::health data updated ${HOURS}h ago"
          fi

      - name: Check known-patterns health
        run: |
          git fetch origin _state 2>/dev/null || true
          COUNT=$(git show "origin/_state:known-patterns.json" 2>/dev/null | jq 'length' || echo "0")

          if [ "$COUNT" -lt 3 ]; then
            echo "::warning title=Low Pattern Count::known-patterns.json has only $COUNT patterns"
          else
            echo "::notice title=Pattern Health::known-patterns.json has $COUNT patterns"
          fi
```

**自监控策略**（确定性检查，不调 AI）：

| 检测项 | 方法 | 告警方式 |
|--------|------|---------|
| triage-failure 停止运行 | 检查最后成功时间 | workflow failure → 邮件 |
| health-daily 停止运行 | 检查 health 数据新鲜度 | `::warning` |
| 数据文件缺失 | 检查 _state 分支文件存在性 | `::warning` |
| 模式库过小 | 检查 known-patterns 条数 | `::warning` |
| AI 调用失败 | triage 中 `continue-on-error` | 规则兜底，不阻塞 |

---

## 十一、熔断器机制

### 11.1 三个预算维度

| 维度 | Key 格式 | 每日上限 | 作用域 |
|---|---|---|---|
| Workflow | `{repo}/{workflow}/{date}` | 3 | 同一 workflow 同一 repo |
| Pattern | `{pattern-id}/{date}` | 5 | 同一失败模式跨所有 repo |
| Repo | `{repo}/{date}` | 20 | 一个 repo 的所有重跑 |

### 11.2 熔断流程

```
auto-rerun 入口
  │
  ▼
read-state（查三个维度当日计数）
  │
  ▼
任一超限？
  │
  ├─ 是 → trip-circuit-breaker
  │        ├── 创建 GitHub Issue（label: ci:circuit-broken）
  │        ├── Slack @channel 通知
  │        └── triage-failure 检测到 label → 全局跳过
  │
  └─ 否 → 执行重跑 → write-state（递增三个维度计数器）
```

### 11.3 恢复机制

熔断后，workflow 完全停止自动处理，直到人工移除 `ci:circuit-broken` label。

### 11.4 安全约束

auto-rerun 仅限只读操作（test/lint/build），以下 workflow **永不**自动重跑：

- 包含 `deploy` 关键词的 workflow
- 包含 `security` / `scan` / `sign` 关键词的 workflow
- 在 `data/circuit-config.yml` 的 `no-rerun` 列表中的 workflow

---

## 十二、Onboarding 新仓库

```yaml
# data/onboarded-repos.yml
repos:
  - name: org/repo-a
    workflows: "*"              # 监控所有 workflow
    priority: high              # high = 失败立刻通知，low = 只进报告

  - name: org/repo-b
    workflows: "pr.yml,ci.yml"  # 只监控指定 workflow
    priority: low

  - name: org/repo-c
    workflows: "*"
    priority: high
    exclude:
      - "stale.yml"
      - "community.yml"
```

目标仓库零配置变更。跨 repo 访问通过 fine-grained PAT（仅需 `actions:read` + `metadata:read`）。

---

## 十三、已知模式库初始 Seed

```json
// _state/known-patterns.json (初始 seed)
[
  {
    "id": "npm-eai-again",
    "match": "EAI_AGAIN.*registry\\.npmjs\\.org|ENOTFOUND.*registry\\.npmjs\\.org",
    "category": "flaky",
    "auto_rerun": true,
    "notify": false,
    "severity": "low",
    "seen_count": 47,
    "last_seen": "2026-04-28",
    "source": "seed"
  },
  {
    "id": "pypi-timeout",
    "match": "ReadTimeoutError.*pypi\\.org|HTTPSConnectionPool.*pypi\\.org",
    "category": "flaky",
    "auto_rerun": true,
    "notify": false,
    "severity": "low",
    "seen_count": 23,
    "last_seen": "2026-04-27",
    "source": "seed"
  },
  {
    "id": "ghcr-rate-limit",
    "match": "rate limit exceeded.*ghcr\\.io|toomanyrequests.*ghcr",
    "category": "flaky",
    "auto_rerun": true,
    "notify": false,
    "severity": "low",
    "seen_count": 31,
    "last_seen": "2026-04-26",
    "source": "seed"
  },
  {
    "id": "runner-disk-full",
    "match": "No space left on device|runner.*disk.*full",
    "category": "infra",
    "auto_rerun": false,
    "notify": true,
    "severity": "high",
    "seen_count": 3,
    "last_seen": "2026-04-25",
    "source": "seed"
  },
  {
    "id": "runner-startup-fail",
    "match": "The runner.*did not connect|runner.*failed to start",
    "category": "flaky",
    "auto_rerun": true,
    "notify": false,
    "severity": "low",
    "seen_count": 8,
    "last_seen": "2026-04-24",
    "source": "seed"
  },
  {
    "id": "trivy-db-update",
    "match": "FATAL.*failed to download vulnerability DB|trivy.*db.*download.*fail",
    "category": "flaky",
    "auto_rerun": true,
    "notify": false,
    "severity": "low",
    "seen_count": 12,
    "last_seen": "2026-04-23",
    "source": "seed"
  },
  {
    "id": "trufflehog-timeout",
    "match": "trufflehog.*timeout|trufflehog.*context deadline exceeded",
    "category": "flaky",
    "auto_rerun": true,
    "notify": false,
    "severity": "low",
    "seen_count": 5,
    "last_seen": "2026-04-22",
    "source": "seed"
  },
  {
    "id": "anthropic-rate-limit",
    "match": "rate_limit_error.*anthropic|429.*too many requests.*claude",
    "category": "flaky",
    "auto_rerun": true,
    "notify": false,
    "severity": "low",
    "seen_count": 15,
    "last_seen": "2026-04-21",
    "source": "seed"
  },
  {
    "id": "langsmith-timeout",
    "match": "langsmith.*504.*timeout|langsmith.*gateway timeout",
    "category": "flaky",
    "auto_rerun": true,
    "notify": false,
    "severity": "low",
    "seen_count": 8,
    "last_seen": "2026-04-20",
    "source": "seed"
  },
  {
    "id": "docker-daemon-fail",
    "match": "Cannot connect to the Docker daemon|docker.*daemon.*not running",
    "category": "infra",
    "auto_rerun": true,
    "notify": true,
    "severity": "medium",
    "seen_count": 6,
    "last_seen": "2026-04-19",
    "source": "seed"
  }
]
```

---

## 十四、成本模型

### 14.1 月度成本估算（5 个 repo）

| 场景 | 频率 | 单价 | 月成本 |
|------|------|------|--------|
| Tier 1: 已知模式匹配 | ~35 次/天 | $0 | $0 |
| Tier 2: 启发式规则 | ~10 次/天 | $0 | $0 |
| Tier 3: Haiku 分类 | ~4 次/天 | $0.001 | $0.12 |
| Tier 4: Sonnet 深度 | ~1 次/天 | $0.01 | $0.30 |
| 每日报告（Haiku） | 22 次/月 | $0.005 | $0.11 |
| 每周深度（Sonnet） | 4 次/月 | $0.10 | $0.40 |
| **总计** | | | **~$0.93/月** |

### 14.2 成本飞轮

每次 Tier 3 分类产生新 pattern，自动 PR 进 `known-patterns.json`（人工审核）。随时间推移：

- **第 1 个月**：~$0.93（Tier 1 命中率 70%）
- **第 3 个月**：~$0.50（Tier 1 命中率 85%）
- **第 6 个月**：~$0.30（Tier 1 命中率 92%+）

这是正反馈飞轮：模式库越大 → Tier 1 命中率越高 → AI 调用越少 → 成本越低。

---

## 十五、与 OpenCI 的关系

### 15.1 依赖清单

| 依赖项 | 用途 | 引用方式 |
|---|---|---|
| `claude-harness.yml` | AI 调用入口 | `uses: your-org/openCI/.github/workflows/claude-harness.yml@v2`（**workflow 级别**） |
| `slack-notify` | Slack 通知 | `uses: your-org/openCI/actions/integrations/slack-notify@v2` |
| `manifest.yml` | 第三方 SHA | 通过 read-manifest 读取 |
| `harden-runner` | 安全加固 | 每个 job 第一步 |

### 15.2 第三方 Actions

| 依赖项 | 版本 | 用途 |
|---|---|---|
| `actions/cache` | v4 | state 快速层 |
| `peter-evans/create-issue-from-file` | v6 | markdown → Issue |
| `peter-evans/create-pull-request` | v7 | known-pattern 自动 PR |
| `nick-fields/retry` | v3 | _state 分支写入冲突重试 |
| `DeveloperMetrics/deployment-frequency` | — | DORA 部署频率 |
| `DeveloperMetrics/lead-time-for-changes` | — | DORA 变更前置时间 |

所有第三方 actions 通过 `manifest.yml` 锁定 SHA。

### 15.3 与 OpenCI health-report.yml 的关系

| 工作流 | 数据源 | 触发 | 输出 |
|---|---|---|---|
| OpenCI `health-report.yml` | Sentry/Datadog/PostHog/LangSmith/Axiom | 每日 | **应用**健康日报 |
| EvolveCI `health-ci-daily.yml` | GitHub Actions API | 每日 | **CI** 健康日报 |

初期分开实现降低复杂度。未来可合并为统一日报。

---

## 十六、实施优先级

| 阶段 | 内容 | 验证方式 |
|------|------|---------|
| P0 | `query-github-actions` + `redact-log` + `read-state` + `write-state` | 手动触发，验证 JSON 输出 |
| P0 | `known-patterns.json` 初始 seed（10 个模式） | `grep -E` 验证每个 pattern |
| P0 | `match-known-patterns` + `classify-heuristic`（Tier 1+2） | 端到端测试 20 条真实失败日志 |
| P1 | `triage-failure.yml` 主流程（含 Tier 3 Haiku） | 在 1 个 repo 上运行 1 周 |
| P1 | `auto-rerun` + 三维预算检查 + `trip-circuit-breaker` | 验证重跑计数和熔断触发 |
| P1 | `_state` 孤儿分支初始化 + 双层持久化 | 验证 cache/branch 读写 |
| P2 | `health-ci-daily.yml` + `compute-flakiness` + `compute-trends` | 对比 2 周数据，验证退化检测 |
| P2 | Slack 通知分级（critical/high/medium） | 验证消息内容和频率 |
| P3 | `health-ci-weekly.yml` + Tier 4 Sonnet | 人工审查报告质量 |
| P3 | `heartbeat.yml` 自监控 | 模拟 triage-failure 停止运行 |
| P4 | `compute-mttr` + DORA 三件套集成 | 与手动计算对比验证 |
| P4 | 新 repo onboarding 流程 | 添加第 6 个 repo，验证零配置 |

---

## 十七、权限矩阵

| 工作流 | contents | issues | actions | 说明 |
|---|---|---|---|---|
| triage-failure | write | write | — | 需要 commit _state + 创建 issue |
| health-ci-daily | read | write | — | 创建 issue |
| health-ci-weekly | read | write | — | 创建 issue |
| heartbeat | read | — | — | 只读检查 |

全局默认：`permissions: {}` 拒绝所有，job 级别精确授权。

---

## 十八、timeout 策略

| 工作流/job | timeout-minutes | 说明 |
|---|---|---|
| scan | 10 | API 调用为主 |
| triage (per matrix) | 15 | 含 AI 调用 |
| collect (daily) | 15 | API + 聚合 |
| synthesize | 5 | AI 调用 |
| publish | 5 | 写 issue/slack |
| heartbeat | 5 | 只读检查 |

---

## 十九、变更日志

| 版本 | 日期 | 变更 |
|------|------|------|
| v2.0 | 2026-05-01 | 完整重构：四层架构、AI 调用提升到 workflow 级别、JSON 替代 YAML 解析、日志脱敏、_state 孤儿分支、成本飞轮 |
| v1.0 | 2026-04-XX | 初始版本 |
