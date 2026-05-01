# EvolveCI — CI 控制塔设计规格

**版本**：v1.0
**定位**：独立 meta-repo，观察所有仓库的 CI 流水线，主动汇报 + 实时分诊
**与 OpenCI 关系**：EvolveCI 消费 OpenCI 的 `claude-harness`，不复制其功能

---

## 一、设计原则

### 1.1 三层分离

| 层 | 职责 | AI 用量 | 运行频率 |
|---|---|---|---|
| **采集层** | 拉数据（gh CLI） | 零 | 每 15 分钟 / 每日 |
| **决策层** | 规则匹配 + 轻量 AI | Haiku，$0.001/次 | 每次失败 |
| **合成层** | 趋势分析 + 报告生成 | Sonnet，$0.10/次 | 每日 / 每周 |

**关键约束**：90% 的失败在决策层就被规则拦截，不调 AI。

### 1.2 状态外部化

所有跨 run 共享的状态（throttle 计数、重跑记录、健康趋势）存储在 `data/` 目录，由 workflow 自身 commit。Git 历史 = 时间序列数据库。

### 1.3 安全默认

- 跨 repo 访问用 fine-grained PAT，只授权 `actions:read` + `metadata:read`
- 不需要目标仓库做任何配置变更
- auto-rerun 仅限只读操作（test/lint/build），永不重跑 deploy/security workflow

### 1.4 复用 OpenCI

- AI 调用统一经由 `uses: your-org/openCI/.github/workflows/claude-harness.yml@v2`
- 不在 EvolveCI 内部直接调用 Claude API
- Slack 通知复用 `uses: your-org/openCI/actions/integrations/slack-notify@v2`

---

## 二、目录结构

```
evolveCI/
├── .github/
│   └── workflows/
│       ├── triage-failure.yml        # 实时分诊（每 15 分钟扫描）
│       ├── health-daily.yml          # 每日汇总
│       ├── health-weekly.yml         # 每周深度分析
│       ├── auto-rerun.yml            # flaky 自动重跑（被 triage 调用）
│       └── heartbeat.yml             # 自监控心跳（每 6 小时）
│
├── actions/
│   ├── _common/                      # 从 OpenCI 引用，不复制
│   │
│   ├── ci-meta/                      # CI 自身可观测
│   │   ├── list-runs/                # 原子：列举多个 repo 的 workflow runs
│   │   ├── fetch-run-logs/           # 原子：拉取失败 job 的 log
│   │   ├── compute-flakiness/        # 原子：计算 workflow 的 flaky 度
│   │   ├── match-known-issues/       # 原子：与已知问题库匹配（纯规则，零 AI）
│   │   ├── classify-failure/         # 原子：AI 分类失败原因（仅未匹配时调用）
│   │   ├── detect-degradation/       # 原子：检测 workflow 健康度退化
│   │   ├── post-triage-result/       # 原子：发评论或建 issue
│   │   └── update-state/             # 原子：更新 data/ 下的状态文件
│   │
│   └── report/
│       ├── aggregate-stats/          # 原子：按 repo/workflow 聚合统计
│       ├── generate-charts/          # 原子：生成 ASCII 趋势图
│       └── publish-report/           # Composite：发 Issue + Slack
│
├── prompts/
│   └── ci-meta/
│       ├── classify-failure.md       # 失败分类 prompt（Haiku）
│       ├── daily-report.md           # 每日报告 prompt（Haiku）
│       └── weekly-deep-dive.md       # 每周深度 prompt（Sonnet）
│
├── data/                             # 状态持久化（git-tracked）
│   ├── known-issues.yml              # 已知失败模式库（AI 自动维护）
│   ├── throttle-state.json           # 重跑/通知节流计数
│   ├── workflow-health.json          # 各 workflow 30 天健康度快照
│   └── onboarded-repos.yml           # 被监控仓库列表及配置
│
└── manifest.yml                      # 第三方依赖 SHA（对齐 OpenCI）
```

---

## 三、数据采集层（零 AI 成本）

### 3.1 list-runs

**职责**：列举多个 repo 在时间窗口内的 workflow runs。

```yaml
# actions/ci-meta/list-runs/action.yml
inputs:
  repos:           # 逗号分隔的 repo 列表，如 "org/repo-a,org/repo-b"
  since:           # 时间窗口，如 "30m" 或 "24h"
  status-filter:   # all | failure | success
  token:           # fine-grained PAT

outputs:
  runs:            # JSON 数组
  count:           # 总数
  failure-count:   # 失败数

runs:
  using: composite
  steps:
    - shell: bash
      run: |
        SINCE=$(date -u -d "-${{ inputs.since }}" +%Y-%m-%dT%H:%M:%SZ)
        ALL_RUNS="[]"

        IFS=',' read -ra REPOS <<< "${{ inputs.repos }}"
        for repo in "${REPOS[@]}"; do
          repo=$(echo "$repo" | xargs)  # trim whitespace

          RUNS=$(gh run list \
            --repo "$repo" \
            --created ">$SINCE" \
            --json databaseId,name,conclusion,createdAt,updatedAt,event,headBranch,headSha,actor,workflowName \
            --limit 100 \
            --jq '.' 2>/dev/null || echo "[]")

          # 给每条 run 加上 repo 字段
          ENRICHED=$(echo "$RUNS" | jq --arg repo "$repo" '[.[] | .repo = $repo]')
          ALL_RUNS=$(echo "$ALL_RUNS $ENRICHED" | jq -s '.[0] + .[1]')
        done

        # 按 status-filter 过滤
        if [ "${{ inputs.status-filter }}" = "failure" ]; then
          ALL_RUNS=$(echo "$ALL_RUNS" | jq '[.[] | select(.conclusion == "failure")]')
        elif [ "${{ inputs.status-filter }}" = "success" ]; then
          ALL_RUNS=$(echo "$ALL_RUNS" | jq '[.[] | select(.conclusion == "success")]')
        fi

        echo "runs=$(echo "$ALL_RUNS" | jq -c '.')" >> $GITHUB_OUTPUT
        echo "count=$(echo "$ALL_RUNS" | jq 'length')" >> $GITHUB_OUTPUT
        echo "failure-count=$(echo "$ALL_RUNS" | jq '[.[] | select(.conclusion == "failure")] | length')" >> $GITHUB_OUTPUT
      env:
        GH_TOKEN: ${{ inputs.token }}
```

**性能约束**：每个 repo 最多拉 100 条 run，避免 API rate limit。5 个 repo × 100 条 = 500 条，远低于 GitHub API 限制。

### 3.2 fetch-run-logs

**职责**：拉取指定 run 的失败 job 日志，只取最后 N 行。

```yaml
# actions/ci-meta/fetch-run-logs/action.yml
inputs:
  repo:
  run-id:
  tail-lines:    # 默认 200
  token:

outputs:
  log:           # 日志文本
  failed-step:   # 失败的 step 名称
  failed-job:    # 失败的 job 名称

runs:
  using: composite
  steps:
    - shell: bash
      run: |
        # 获取失败的 job
        JOBS=$(gh run view ${{ inputs.run-id }} \
          --repo ${{ inputs.repo }} \
          --json jobs \
          --jq '[.jobs[] | select(.conclusion == "failure")]')

        FAILED_JOB=$(echo "$JOBS" | jq -r '.[0].name // "unknown"')
        FAILED_STEP=$(echo "$JOBS" | jq -r '.[0].steps[] | select(.conclusion == "failure") | .name' | head -1)

        # 拉取日志，只取最后 N 行
        LOG=$(gh run view ${{ inputs.run-id }} \
          --repo ${{ inputs.repo }} \
          --log-failed \
          2>/dev/null | tail -${{ inputs.tail-lines }})

        # 写入输出（base64 编码避免特殊字符问题）
        echo "log=$(echo "$LOG" | base64 -w0)" >> $GITHUB_OUTPUT
        echo "failed-step=$FAILED_STEP" >> $GITHUB_OUTPUT
        echo "failed-job=$FAILED_JOB" >> $GITHUB_OUTPUT
      env:
        GH_TOKEN: ${{ inputs.token }}
```

### 3.3 compute-flakiness

**职责**：计算指定 workflow 最近 N 次运行的失败率。

```yaml
# actions/ci-meta/compute-flakiness/action.yml
inputs:
  repo:
  workflow-name:
  lookback:        # 默认 20
  token:

outputs:
  flakiness-score: # 0-100 的百分比
  total-runs:      # 总运行次数
  failed-runs:     # 失败次数
  recent-failures: # 最近 5 次的结论数组

runs:
  using: composite
  steps:
    - shell: bash
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

        echo "flakiness-score=$SCORE" >> $GITHUB_OUTPUT
        echo "total-runs=$TOTAL" >> $GITHUB_OUTPUT
        echo "failed-runs=$FAILED" >> $GITHUB_OUTPUT
        echo "recent-failures=$RECENT" >> $GITHUB_OUTPUT
      env:
        GH_TOKEN: ${{ inputs.token }}
```

---

## 四、决策层（规则优先，AI 兜底）

### 4.1 match-known-issues（零 AI 成本）

**职责**：在调 AI 之前，先用正则匹配已知失败模式。命中率目标 > 80%。

```yaml
# actions/ci-meta/match-known-issues/action.yml
inputs:
  log:                  # 日志文本（base64）
  known-issues-path:    # 默认 data/known-issues.yml

outputs:
  matched:              # true | false
  pattern-id:           # 匹配到的 pattern ID
  category:             # 匹配到的 category
  auto-rerun:           # 是否应自动重跑
  notify:               # 是否应通知
  severity:             # 严重程度

runs:
  using: composite
  steps:
    - shell: bash
      id: match
      run: |
        LOG=$(echo "${{ inputs.log }}" | base64 -d)
        ISSUES_FILE="${{ inputs.known-issues-path }}"

        if [ ! -f "$ISSUES_FILE" ]; then
          echo "matched=false" >> $GITHUB_OUTPUT
          exit 0
        fi

        # 遍历所有 pattern，用 grep -E 匹配
        MATCHED_ID=""
        MATCHED_CATEGORY=""
        MATCHED_RERUN="false"
        MATCHED_NOTIFY="false"
        MATCHED_SEVERITY="low"

        while IFS= read -r line; do
          # 跳过注释和空行
          [[ "$line" =~ ^[[:space:]]*# ]] && continue
          [[ -z "$line" ]] && continue

          # 解析 id 行
          if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*id:[[:space:]]*(.+)$ ]]; then
            CURRENT_ID="${BASH_REMATCH[1]}"
            CURRENT_ID=$(echo "$CURRENT_ID" | xargs)
          fi

          # 解析 match 行
          if [[ "$line" =~ ^[[:space:]]*match:[[:space:]]*\"(.+)\"$ ]]; then
            PATTERN="${BASH_REMATCH[1]}"
            if echo "$LOG" | grep -qE "$PATTERN" 2>/dev/null; then
              MATCHED_ID="$CURRENT_ID"
              # 找到匹配，继续读取该 pattern 的其他字段
              FOUND=true
            fi
          fi

          # 读取匹配 pattern 的属性
          if [ "$FOUND" = true ] && [ -n "$MATCHED_ID" ]; then
            if [[ "$line" =~ category:[[:space:]]*(.+) ]]; then
              MATCHED_CATEGORY=$(echo "${BASH_REMATCH[1]}" | xargs)
            fi
            if [[ "$line" =~ auto_rerun:[[:space:]]*(.+) ]]; then
              MATCHED_RERUN=$(echo "${BASH_REMATCH[1]}" | xargs)
            fi
            if [[ "$line" =~ notify:[[:space:]]*(.+) ]]; then
              MATCHED_NOTIFY=$(echo "${BASH_REMATCH[1]}" | xargs)
            fi
            if [[ "$line" =~ severity:[[:space:]]*(.+) ]]; then
              MATCHED_SEVERITY=$(echo "${BASH_REMATCH[1]}" | xargs)
            fi
            # 遇到下一个 id 行，停止读取
            if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*id: ]] && [ "$FOUND" = true ]; then
              break
            fi
          fi
        done < "$ISSUES_FILE"

        if [ -n "$MATCHED_ID" ]; then
          echo "matched=true" >> $GITHUB_OUTPUT
          echo "pattern-id=$MATCHED_ID" >> $GITHUB_OUTPUT
          echo "category=$MATCHED_CATEGORY" >> $GITHUB_OUTPUT
          echo "auto-rerun=$MATCHED_RERUN" >> $GITHUB_OUTPUT
          echo "notify=$MATCHED_NOTIFY" >> $GITHUB_OUTPUT
          echo "severity=$MATCHED_SEVERITY" >> $GITHUB_OUTPUT
        else
          echo "matched=false" >> $GITHUB_OUTPUT
        fi
```

### 4.2 classify-failure（AI 调用，仅未匹配时触发）

**职责**：对未匹配已知模式的失败进行 AI 分类。

**调用条件**：`if: steps.match.outputs.matched != 'true'`

```yaml
# actions/ci-meta/classify-failure/action.yml
inputs:
  workflow-name:
  failed-step:
  flakiness-score:
  log:                  # base64 编码的日志
  repo:
  run-id:

outputs:
  category:             # flaky | infra | code | dependency | security | unknown
  severity:             # low | medium | high | critical
  summary:              # 一句话总结
  should-notify:        # true | false
  should-rerun:         # true | false
  matched-pattern:      # 可复用的失败签名

runs:
  using: composite
  steps:
    - name: Decode log
      id: decode
      shell: bash
      run: |
        echo "${{ inputs.log }}" | base64 -d > /tmp/failure-log.txt
        # 截断到 8KB（Haiku 上下文限制）
        truncate -s 8192 /tmp/failure-log.txt

    - name: Classify with AI
      uses: your-org/openCI/.github/workflows/claude-harness.yml@v2
      id: ai
      with:
        task: ci-classify-failure
        prompt-path: prompts/ci-meta/classify-failure.md
        model: claude-haiku-4-5-20251001
        max-turns: 1
        context: |
          {
            "workflow_name": "${{ inputs.workflow-name }}",
            "failed_step": "${{ inputs.failed-step }}",
            "flakiness_score": ${{ inputs.flakiness-score }},
            "repo": "${{ inputs.repo }}",
            "run_id": "${{ inputs.run-id }}",
            "log_tail": $(cat /tmp/failure-log.txt | jq -Rs .)
          }

    - name: Parse AI output
      id: parse
      shell: bash
      run: |
        RESULT='${{ steps.ai.outputs.result }}'

        echo "category=$(echo "$RESULT" | jq -r '.category // "unknown"')" >> $GITHUB_OUTPUT
        echo "severity=$(echo "$RESULT" | jq -r '.severity // "medium"')" >> $GITHUB_OUTPUT
        echo "summary=$(echo "$RESULT" | jq -r '.summary // "unknown failure"')" >> $GITHUB_OUTPUT
        echo "should-notify=$(echo "$RESULT" | jq -r '.should_notify // true')" >> $GITHUB_OUTPUT
        echo "should-rerun=$(echo "$RESULT" | jq -r '.should_rerun // false')" >> $GITHUB_OUTPUT
        echo "matched-pattern=$(echo "$RESULT" | jq -r '.matched_pattern // ""')" >> $GITHUB_OUTPUT
```

### 4.3 classify-failure prompt

```markdown
<!-- prompts/ci-meta/classify-failure.md -->
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
```

### 4.4 detect-degradation（纯计算，零 AI）

**职责**：检测 workflow 健康度是否在退化。

```yaml
# actions/ci-meta/detect-degradation/action.yml
inputs:
  current-flakiness:      # 当前 flakiness score
  workflow-name:
  repo:

outputs:
  is-degrading:           # true | false
  trend:                  # improving | stable | degrading
  current-score:
  seven-day-avg:
  delta:                  # 当前 - 7日均值

runs:
  using: composite
  steps:
    - shell: bash
      run: |
        CURRENT=${{ inputs.current-flakiness }}
        HEALTH_FILE="data/workflow-health.json"

        # 读取该 workflow 的历史数据
        if [ -f "$HEALTH_FILE" ]; then
          HISTORY=$(jq -r '.["${{ inputs.repo }}"]["${{ inputs.workflow-name }}"] // []' "$HEALTH_FILE")
          SEVEN_DAY=$(echo "$HISTORY" | jq -s '.[-7:] | if length > 0 then add / length else 0 end')
        else
          SEVEN_DAY=0
        fi

        DELTA=$(( CURRENT - SEVEN_DAY ))

        if [ "$DELTA" -gt 10 ]; then
          TREND="degrading"
          IS_DEGRADING="true"
        elif [ "$DELTA" -lt -10 ]; then
          TREND="improving"
          IS_DEGRADING="false"
        else
          TREND="stable"
          IS_DEGRADING="false"
        fi

        echo "is-degrading=$IS_DEGRADING" >> $GITHUB_OUTPUT
        echo "trend=$TREND" >> $GITHUB_OUTPUT
        echo "current-score=$CURRENT" >> $GITHUB_OUTPUT
        echo "seven-day-avg=$SEVEN_DAY" >> $GITHUB_OUTPUT
        echo "delta=$DELTA" >> $GITHUB_OUTPUT
```

---

## 五、实时分诊工作流

### 5.1 triage-failure.yml

```yaml
name: "Triage: Scan & Classify Failures"
on:
  schedule:
    - cron: '*/15 * * * *'     # 每 15 分钟
  workflow_dispatch:

permissions: {}

jobs:
  scan:
    runs-on: ubuntu-latest
    permissions:
      contents: write          # 需要 commit data/ 更新
      issues: write            # 需要创建 issue
    steps:
      - uses: actions/checkout@{SHA}

      - name: Load onboarded repos
        id: repos
        run: |
          REPOS=$(yq '.repos | map(.name) | join(",")' data/onboarded-repos.yml)
          echo "list=$REPOS" >> $GITHUB_OUTPUT

      - name: Scan for failures
        uses: ./actions/ci-meta/list-runs
        id: runs
        with:
          repos: ${{ steps.repos.outputs.list }}
          since: 30m
          status-filter: failure
          token: ${{ secrets.CROSS_REPO_PAT }}

      - name: Skip if no failures
        if: steps.runs.outputs.failure-count == '0'
        run: echo "No failures found, exiting."

  triage:
    needs: scan
    if: needs.scan.outputs.failure-count != '0'
    runs-on: ubuntu-latest
    strategy:
      max-parallel: 3
      matrix:
        # 动态生成，最多处理 10 个失败（避免一次扫太多）
        run: ${{ fromJson(needs.scan.outputs.runs)[0:10] }}
    steps:
      - uses: actions/checkout@{SHA}

      - name: Check throttle
        id: throttle
        run: |
          # 检查这个 run 是否已经在最近 15 分钟内被分诊过
          RUN_ID="${{ matrix.run.databaseId }}"
          REPO="${{ matrix.run.repo }}"
          STATE="data/throttle-state.json"

          if [ -f "$STATE" ]; then
            LAST_TRIAGED=$(jq -r ".last_triage[\"$REPO/$RUN_ID\"] // 0" "$STATE")
            NOW=$(date +%s)
            ELAPSED=$(( NOW - LAST_TRIAGED ))

            if [ "$ELAPSED" -lt 900 ]; then
              echo "skip=true" >> $GITHUB_OUTPUT
              echo "Skipping $REPO/$RUN_ID (triaged ${ELAPSED}s ago)"
              exit 0
            fi
          fi
          echo "skip=false" >> $GITHUB_OUTPUT

      - name: Fetch logs
        if: steps.throttle.outputs.skip != 'true'
        uses: ./actions/ci-meta/fetch-run-logs
        id: logs
        with:
          repo: ${{ matrix.run.repo }}
          run-id: ${{ matrix.run.databaseId }}
          tail-lines: 200
          token: ${{ secrets.CROSS_REPO_PAT }}

      - name: Match known issues
        if: steps.throttle.outputs.skip != 'true'
        uses: ./actions/ci-meta/match-known-issues
        id: match
        with:
          log: ${{ steps.logs.outputs.log }}

      - name: Classify with AI (only if no match)
        if: steps.throttle.outputs.skip != 'true' && steps.match.outputs.matched != 'true'
        uses: ./actions/ci-meta/classify-failure
        id: classify
        with:
          workflow-name: ${{ matrix.run.workflowName }}
          failed-step: ${{ steps.logs.outputs.failed-step }}
          flakiness-score: 0        # 初始值，后续从 health 数据读取
          log: ${{ steps.logs.outputs.log }}
          repo: ${{ matrix.run.repo }}
          run-id: ${{ matrix.run.databaseId }}

      - name: Dispatch action
        if: steps.throttle.outputs.skip != 'true'
        run: |
          # 确定最终分类结果
          if [ "${{ steps.match.outputs.matched }}" = "true" ]; then
            CATEGORY="${{ steps.match.outputs.category }}"
            SEVERITY="${{ steps.match.outputs.severity }}"
            SHOULD_RERUN="${{ steps.match.outputs.auto-rerun }}"
            SHOULD_NOTIFY="${{ steps.match.outputs.notify }}"
            SUMMARY="Known pattern: ${{ steps.match.outputs.pattern-id }}"
          else
            CATEGORY="${{ steps.classify.outputs.category }}"
            SEVERITY="${{ steps.classify.outputs.severity }}"
            SHOULD_RERUN="${{ steps.classify.outputs.should-rerun }}"
            SHOULD_NOTIFY="${{ steps.classify.outputs.should-notify }}"
            SUMMARY="${{ steps.classify.outputs.summary }}"
          fi

          echo "category=$CATEGORY" >> $GITHUB_OUTPUT
          echo "severity=$SEVERITY" >> $GITHUB_OUTPUT
          echo "should-rerun=$SHOULD_RERUN" >> $GITHUB_OUTPUT
          echo "should-notify=$SHOULD_NOTIFY" >> $GITHUB_OUTPUT
          echo "summary=$SUMMARY" >> $GITHUB_OUTPUT
        id: dispatch

      - name: Auto-rerun (flaky only)
        if: steps.dispatch.outputs.should-rerun == 'true'
        uses: ./.github/workflows/auto-rerun.yml
        with:
          repo: ${{ matrix.run.repo }}
          run-id: ${{ matrix.run.databaseId }}
          workflow-name: ${{ matrix.run.workflowName }}

      - name: Create issue (non-flaky failures)
        if: steps.dispatch.outputs.should-notify == 'true' && steps.dispatch.outputs.category != 'flaky'
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          REPO="${{ matrix.run.repo }}"
          RUN_ID="${{ matrix.run.databaseId }}"
          WF="${{ matrix.run.workflowName }}"
          BRANCH="${{ matrix.run.headBranch }}"
          CATEGORY="${{ steps.dispatch.outputs.category }}"
          SEVERITY="${{ steps.dispatch.outputs.severity }}"
          SUMMARY="${{ steps.dispatch.outputs.summary }}"

          # 检查是否已有同 repo/workflow 的 open issue
          EXISTING=$(gh issue list \
            --label "ci/$CATEGORY" \
            --search "$WF in:title" \
            --state open \
            --json number \
            --limit 1 \
            --jq '.[0].number // empty')

          BODY=$(cat <<EOF
          ## CI Failure: $WF

          - **Repo**: $REPO
          - **Run**: [#${RUN_ID}](https://github.com/$REPO/actions/runs/$RUN_ID)
          - **Branch**: $BRANCH
          - **Category**: $CATEGORY
          - **Severity**: $SEVERITY
          - **Summary**: $SUMMARY
          EOF
          )

          if [ -n "$EXISTING" ]; then
            # 追加到已有 issue
            gh issue comment "$EXISTING" --body "$BODY"
          else
            # 创建新 issue
            gh issue create \
              --title "CI [$CATEGORY]: $WF - $SUMMARY" \
              --label "ci/$CATEGORY,severity/$SEVERITY" \
              --body "$BODY"
          fi

      - name: Notify Slack (critical/high)
        if: steps.dispatch.outputs.should-notify == 'true' && (steps.dispatch.outputs.severity == 'critical' || steps.dispatch.outputs.severity == 'high')
        uses: your-org/openCI/actions/integrations/slack-notify@v2
        with:
          webhook-url: ${{ secrets.SLACK_CI_WEBHOOK }}
          status: failure
          title: "CI ${{ steps.dispatch.outputs.severity }}: ${{ matrix.run.workflowName }}"
          message: "${{ steps.dispatch.outputs.summary }} — ${{ matrix.run.repo }}"

      - name: Update throttle state
        if: always()
        run: |
          STATE="data/throttle-state.json"
          RUN_ID="${{ matrix.run.databaseId }}"
          REPO="${{ matrix.run.repo }}"
          NOW=$(date +%s)

          if [ ! -f "$STATE" ]; then
            echo '{"last_triage":{},"reruns":{}}' > "$STATE"
          fi

          # 用 jq 更新
          jq --arg key "$REPO/$RUN_ID" --argjson ts "$NOW" \
            '.last_triage[$key] = $ts' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"

      - name: Learn new pattern
        if: steps.classify.outputs.matched-pattern != '' && steps.match.outputs.matched != 'true'
        run: |
          PATTERN="${{ steps.classify.outputs.matched-pattern }}"
          CATEGORY="${{ steps.dispatch.outputs.category }}"
          ISSUES_FILE="data/known-issues.yml"

          # 检查 pattern 是否已存在
          if ! grep -qF "$PATTERN" "$ISSUES_FILE" 2>/dev/null; then
            # 生成唯一 ID
            ID=$(echo "$PATTERN" | md5sum | head -c 8)

            cat >> "$ISSUES_FILE" <<EOF

          - id: ai-$ID
            match: "$PATTERN"
            category: $CATEGORY
            auto_rerun: ${{ steps.dispatch.outputs.should-rerun }}
            notify: ${{ steps.dispatch.outputs.should-notify }}
            severity: ${{ steps.dispatch.outputs.severity }}
            seen_count: 1
            last_seen: $(date +%Y-%m-%d)
            source: ai-classify
          EOF

            echo "::notice title=New Pattern Learned::id=ai-$ID pattern=$PATTERN"
          fi

      - name: Commit state updates
        if: always()
        run: |
          git config user.name "evolveCI bot"
          git config user.email "bot@evolveci.dev"
          git add data/
          git diff --cached --quiet || git commit -m "chore: update CI state [skip ci]"
          git push || echo "Push failed, state will be retried next run"
```

---

## 六、自动重跑工作流

### 6.1 auto-rerun.yml

```yaml
name: "Auto-Rerun Flaky Workflow"
on:
  workflow_call:
    inputs:
      repo:          { type: string, required: true }
      run-id:        { type: string, required: true }
      workflow-name: { type: string, required: true }

permissions: {}

jobs:
  rerun:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - name: Check rerun quota
        id: quota
        run: |
          STATE="data/throttle-state.json"
          REPO="${{ inputs.repo }}"
          WF="${{ inputs.workflow-name }}"
          TODAY=$(date +%Y-%m-%d)
          KEY="$REPO/$WF/$TODAY"

          if [ -f "$STATE" ]; then
            COUNT=$(jq -r ".reruns[\"$KEY\"] // 0" "$STATE")
          else
            COUNT=0
          fi

          MAX_RERUNS=3

          if [ "$COUNT" -ge "$MAX_RERUNS" ]; then
            echo "can-rerun=false" >> $GITHUB_OUTPUT
            echo "::warning title=Rerun Quota Exceeded::$REPO/$WF already rerun $COUNT times today"
          else
            echo "can-rerun=true" >> $GITHUB_OUTPUT
          fi

      - name: Rerun workflow
        if: steps.quota.outputs.can-rerun == 'true'
        run: |
          gh run rerun ${{ inputs.run-id }} \
            --repo ${{ inputs.repo }} \
            --failed
        env:
          GH_TOKEN: ${{ secrets.CROSS_REPO_PAT }}

      - name: Update rerun count
        if: steps.quota.outputs.can-rerun == 'true'
        run: |
          STATE="data/throttle-state.json"
          REPO="${{ inputs.repo }}"
          WF="${{ inputs.workflow-name }}"
          TODAY=$(date +%Y-%m-%d)
          KEY="$REPO/$WF/$TODAY"

          if [ ! -f "$STATE" ]; then
            echo '{"last_triage":{},"reruns":{}}' > "$STATE"
          fi

          jq --arg key "$KEY" \
            '.reruns[$key] = ((.reruns[$key] // 0) + 1)' "$STATE" > "$STATE.tmp" \
            && mv "$STATE.tmp" "$STATE"
```

---

## 七、每日汇总报告

### 7.1 health-daily.yml

```yaml
name: "Health: Daily Report"
on:
  schedule:
    - cron: '0 1 * * 1-5'    # 工作日 UTC 01:00 = 北京时间 09:00
  workflow_dispatch:

permissions: {}

jobs:
  collect:
    runs-on: ubuntu-latest
    outputs:
      stats: ${{ steps.aggregate.outputs.stats }}
    steps:
      - uses: actions/checkout@{SHA}

      - name: Load repos
        id: repos
        run: |
          REPOS=$(yq '.repos | map(.name) | join(",")' data/onboarded-repos.yml)
          echo "list=$REPOS" >> $GITHUB_OUTPUT

      - name: Collect all runs (24h)
        uses: ./actions/ci-meta/list-runs
        id: all-runs
        with:
          repos: ${{ steps.repos.outputs.list }}
          since: 24h
          status-filter: all
          token: ${{ secrets.CROSS_REPO_PAT }}

      - name: Compute flakiness per workflow
        id: flakiness
        run: |
          # 对每个 repo/workflow 组合计算 flakiness
          RUNS='${{ steps.all-runs.outputs.runs }}'

          # 按 repo+workflow 分组统计
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
        run: |
          # 与 workflow-health.json 中的历史数据对比
          FLAKINESS='${{ steps.flakiness.outputs.stats }}'
          HEALTH_FILE="data/workflow-health.json"

          DEGRADATIONS="[]"

          echo "$FLAKINESS" | jq -c '.[]' | while read -r item; do
            REPO=$(echo "$item" | jq -r '.repo')
            WF=$(echo "$item" | jq -r '.workflow')
            CURRENT=$(echo "$item" | jq -r '.failure_rate')

            # 读取 7 日均值
            if [ -f "$HEALTH_FILE" ]; then
              AVG=$(jq -r ".[\"$REPO\"][\"$WF\"].seven_day_avg // 0" "$HEALTH_FILE")
            else
              AVG=0
            fi

            DELTA=$(( CURRENT - AVG ))
            if [ "$DELTA" -gt 10 ]; then
              DEGRADATIONS=$(echo "$DEGRADATIONS" | jq \
                --arg repo "$REPO" \
                --arg wf "$WF" \
                --argjson current "$CURRENT" \
                --argjson avg "$AVG" \
                --argjson delta "$DELTA" \
                '. + [{"repo": $repo, "workflow": $wf, "current": $current, "seven_day_avg": $avg, "delta": $delta}]')
            fi
          done

          echo "degradations=$(echo "$DEGRADATIONS" | jq -c '.')" >> $GITHUB_OUTPUT

      - name: Update health history
        run: |
          HEALTH_FILE="data/workflow-health.json"
          TODAY=$(date +%Y-%m-%d)
          FLAKINESS='${{ steps.flakiness.outputs.stats }}'

          if [ ! -f "$HEALTH_FILE" ]; then
            echo '{}' > "$HEALTH_FILE"
          fi

          # 写入今天的快照
          echo "$FLAKINESS" | jq -c '.[]' | while read -r item; do
            REPO=$(echo "$item" | jq -r '.repo')
            WF=$(echo "$item" | jq -r '.workflow')
            RATE=$(echo "$item" | jq -r '.failure_rate')

            jq --arg repo "$REPO" --arg wf "$WF" --argjson rate "$RATE" --arg date "$TODAY" \
              '.[$repo][$wf].daily[$date] = $rate |
               .[$repo][$wf].seven_day_avg = (.[$repo][$wf].daily | to_entries | .[-7:] | map(.value) | if length > 0 then add / length | round else 0 end)' \
              "$HEALTH_FILE" > "$HEALTH_FILE.tmp" && mv "$HEALTH_FILE.tmp" "$HEALTH_FILE"
          done

      - name: Aggregate stats for AI
        id: aggregate
        run: |
          TOTAL_RUNS='${{ steps.all-runs.outputs.count }}'
          TOTAL_FAILURES='${{ steps.all-runs.outputs.failure-count }}'
          FLAKINESS='${{ steps.flakiness.outputs.stats }}'
          DEGRADATIONS='${{ steps.degradations.outputs.degradations }}'

          if [ "$TOTAL_RUNS" -gt 0 ]; then
            FAILURE_RATE=$(( (TOTAL_FAILURES * 100) / TOTAL_RUNS ))
          else
            FAILURE_RATE=0
          fi

          # 读取昨天的对比数据
          HEALTH_FILE="data/workflow-health.json"
          YESTERDAY=$(date -d "yesterday" +%Y-%m-%d)
          if [ -f "$HEALTH_FILE" ]; then
            YESTERDAY_AVG=$(jq '[.[][] | .daily["'"$YESTERDAY"'"] // empty] | if length > 0 then add / length | round else 0 end' "$HEALTH_FILE")
          else
            YESTERDAY_AVG=0
          fi

          STATS=$(jq -n \
            --argjson total "$TOTAL_RUNS" \
            --argjson failures "$TOTAL_FAILURES" \
            --argjson rate "$FAILURE_RATE" \
            --argjson yesterday "$YESTERDAY_AVG" \
            --argjson flakiness "$FLAKINESS" \
            --argjson degradations "$DEGRADATIONS" \
            '{
              total_runs: $total,
              total_failures: $failures,
              failure_rate: $rate,
              yesterday_avg_rate: $yesterday,
              workflows: $flakiness,
              degradations: $degradations
            }')

          echo "stats=$(echo "$STATS" | jq -c '.')" >> $GITHUB_OUTPUT

  synthesize:
    needs: collect
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@{SHA}

      - name: Generate report
        uses: your-org/openCI/.github/workflows/claude-harness.yml@v2
        id: report
        with:
          task: ci-daily-report
          prompt-path: prompts/ci-meta/daily-report.md
          model: claude-haiku-4-5-20251001
          max-turns: 1
          context: ${{ needs.collect.outputs.stats }}

      - name: Publish report
        run: |
          REPORT='${{ steps.report.outputs.result }}'
          TODAY=$(date +%Y-%m-%d)

          # 创建 GitHub Issue
          gh issue create \
            --title "CI Health Report - $TODAY" \
            --label "ci-report" \
            --body "$REPORT"
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}

      - name: Post to Slack
        uses: your-org/openCI/actions/integrations/slack-notify@v2
        with:
          webhook-url: ${{ secrets.SLACK_CI_WEBHOOK }}
          status: info
          title: "CI Health Report - $(date +%Y-%m-%d)"
          message: ${{ steps.report.outputs.result }}

      - name: Commit health data
        run: |
          git config user.name "evolveCI bot"
          git config user.email "bot@evolveci.dev"
          git add data/
          git diff --cached --quiet || git commit -m "chore: update daily health data [skip ci]"
          git push
```

---

## 八、每日报告 prompt

```markdown
<!-- prompts/ci-meta/daily-report.md -->
你是 CI 健康报告生成器。基于以下统计数据，生成一份简洁的日报。

数据：
{{stats}}

输出格式（严格遵循）：

# CI Health Report - {今日日期}

## TL;DR
- 整体健康度: {100 - failure_rate}%（{与昨日对比趋势}）
- {1-2 条最重要的事}

## 关键指标
| 指标 | 今日 | 昨日 | 趋势 |
|------|------|------|------|
| 总运行 | {total_runs} | - | - |
| 失败率 | {failure_rate}% | {yesterday_avg_rate}% | {↑/↓/→} |

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
```

---

## 九、自监控设计

### 9.1 heartbeat.yml

```yaml
name: "Heartbeat: Self-Monitor"
on:
  schedule:
    - cron: '0 */6 * * *'    # 每 6 小时
  workflow_dispatch:

permissions:
  contents: read

jobs:
  heartbeat:
    runs-on: ubuntu-latest
    steps:
      - name: Check last successful run
        run: |
          # 检查 triage-failure 最近一次成功时间
          LAST_SUCCESS=$(gh run list \
            --workflow triage-failure.yml \
            --status success \
            --limit 1 \
            --json updatedAt \
            --jq '.[0].updatedAt // "never"' 2>/dev/null || echo "never")

          if [ "$LAST_SUCCESS" = "never" ]; then
            echo "::warning title=Control Tower Alert::triage-failure has never run successfully"
            exit 0
          fi

          # 检查是否超过 24 小时没成功过
          LAST_TS=$(date -d "$LAST_SUCCESS" +%s)
          NOW=$(date +%s)
          HOURS_SINCE=$(( (NOW - LAST_TS) / 3600 ))

          if [ "$HOURS_SINCE" -gt 24 ]; then
            echo "::error title=Control Tower Down::triage-failure hasn't succeeded in ${HOURS_SINCE}h"
            # 用 GitHub 的原生通知（workflow failure 会自动发邮件）
            exit 1
          fi

          echo "::notice title=Heartbeat OK::last triage-failure success: ${HOURS_SINCE}h ago"

      - name: Check data freshness
        run: |
          # 检查 workflow-health.json 是否在 48 小时内更新过
          HEALTH_FILE="data/workflow-health.json"
          if [ ! -f "$HEALTH_FILE" ]; then
            echo "::warning title=Missing Health Data::workflow-health.json not found"
            exit 0
          fi

          LAST_MODIFIED=$(git log -1 --format="%at" -- "$HEALTH_FILE" 2>/dev/null || echo "0")
          NOW=$(date +%s)
          HOURS_OLD=$(( (NOW - LAST_MODIFIED) / 3600 ))

          if [ "$HOURS_OLD" -gt 48 ]; then
            echo "::warning title=Stale Health Data::workflow-health.json is ${HOURS_OLD}h old"
          else
            echo "::notice title=Data Fresh::health data updated ${HOURS_OLD}h ago"
          fi
```

**自监控策略**：

| 检测项 | 方法 | 告警方式 |
|--------|------|---------|
| triage-failure 停止运行 | heartbeat 检查最后成功时间 | GitHub 原生 workflow failure 邮件 |
| health-daily 停止运行 | heartbeat 检查 health 数据新鲜度 | `::warning` annotation |
| 数据文件损坏 | workflow 自身 commit 失败 | `git push` 失败 → `::error` |
| AI 调用失败 | claude-harness 返回错误 | 继续用规则兜底，不阻塞 |

**为什么不用 AI 监控自己**：控制塔的心跳应该是确定性的——要么跑通，要么失败。引入 AI 会让心跳本身变得不可靠。

---

## 十、已知问题库格式

```yaml
# data/known-issues.yml
# 由 AI 自动维护，人工可补充
# 每次 AI 分类出新 pattern 会自动追加

patterns:
  # ── 网络 / Registry ─────────────────────────────────────────
  - id: npm-eai-again
    match: "EAI_AGAIN.*registry\\.npmjs\\.org|ENOTFOUND.*registry\\.npmjs\\.org"
    category: flaky
    auto_rerun: true
    notify: false
    severity: low
    seen_count: 47
    last_seen: 2026-04-28

  - id: pypi-timeout
    match: "ReadTimeoutError.*pypi\\.org|HTTPSConnectionPool.*pypi\\.org"
    category: flaky
    auto_rerun: true
    notify: false
    severity: low
    seen_count: 23

  - id: ghcr-rate-limit
    match: "rate limit exceeded.*ghcr\\.io|toomanyrequests.*ghcr"
    category: flaky
    auto_rerun: true
    notify: false
    severity: low
    seen_count: 31

  # ── GitHub Actions Runner ───────────────────────────────────
  - id: runner-disk-full
    match: "No space left on device|runner.*disk.*full"
    category: infra
    auto_rerun: false
    notify: true
    severity: high
    seen_count: 3

  - id: runner-startup-fail
    match: "The runner.*did not connect|runner.*failed to start"
    category: flaky
    auto_rerun: true
    notify: false
    severity: low
    seen_count: 8

  # ── 安全扫描 ────────────────────────────────────────────────
  - id: trivy-db-update
    match: "FATAL.*failed to download vulnerability DB|trivy.*db.*download.*fail"
    category: flaky
    auto_rerun: true
    notify: false
    severity: low
    seen_count: 12

  - id: trufflehog-timeout
    match: "trufflehog.*timeout|trufflehog.*context deadline exceeded"
    category: flaky
    auto_rerun: true
    notify: false
    severity: low
    seen_count: 5

  # ── AI / LLM 相关 ──────────────────────────────────────────
  - id: anthropic-rate-limit
    match: "rate_limit_error.*anthropic|429.*too many requests.*claude"
    category: flaky
    auto_rerun: true
    notify: false
    severity: low
    seen_count: 15

  - id: langsmith-timeout
    match: "langsmith.*504.*timeout|langsmith.*gateway timeout"
    category: flaky
    auto_rerun: true
    notify: false
    severity: low
    seen_count: 8
```

---

## 十一、成本模型

### 11.1 每次失败分诊的成本

| 步骤 | 是否调 AI | 模型 | Token 估算 | 成本 |
|------|----------|------|-----------|------|
| list-runs | 否 | - | - | $0 |
| fetch-run-logs | 否 | - | - | $0 |
| match-known-issues | 否 | - | - | $0 |
| classify-failure（仅未匹配时） | 是 | Haiku | ~2K input + 500 output | ~$0.001 |
| **总计（命中已知模式）** | | | | **$0** |
| **总计（未命中）** | | | | **~$0.001** |

### 11.2 每日报告成本

| 步骤 | 模型 | Token 估算 | 成本 |
|------|------|-----------|------|
| aggregate-stats | 否 | - | $0 |
| daily-report（Haiku） | Haiku | ~3K input + 1K output | ~$0.005 |

### 11.3 每周深度分析成本

| 步骤 | 模型 | Token 估算 | 成本 |
|------|------|-----------|------|
| weekly-deep-dive（Sonnet） | Sonnet | ~10K input + 3K output | ~$0.10 |

### 11.4 月度总成本估算（5 个 repo）

| 场景 | 频率 | 单价 | 月成本 |
|------|------|------|--------|
| 已知模式匹配 | ~40 次/天 | $0 | $0 |
| AI 分类（新失败） | ~10 次/天 | $0.001 | $0.30 |
| 每日报告 | 22 次/月 | $0.005 | $0.11 |
| 每周深度 | 4 次/月 | $0.10 | $0.40 |
| **总计** | | | **~$0.81/月** |

**成本随时间递减**：随着 known-issues.yml 积累更多 pattern，AI 分类调用占比会从 20% 降到 <5%。

---

## 十二、与原方案的关键差异

| 维度 | 原方案 | 优化后 |
|------|--------|--------|
| AI 调用 | 每次失败都调 | 规则匹配优先，仅未命中时调 Haiku |
| 趋势检测 | 无 | workflow-health.json + detect-degradation |
| 重跑安全 | 无上限 | 每 workflow 每天最多 3 次 |
| 状态持久化 | 无 | data/ 目录 git-tracked |
| 自监控 | "套娃"一笔带过 | heartbeat + 确定性检查 |
| 与 OpenCI 关系 | 未定义 | 引用 claude-harness，不复制 |
| 成本模型 | 未估算 | ~$0.81/月（5 repo） |
| 通知节流 | 未定义 | throttle-state.json + 精确 dispatch matrix |
| 模式学习 | 提到了但没设计 | 自动 PR 到 known-issues.yml |

---

## 十三、实施优先级

| 阶段 | 内容 | 验证方式 |
|------|------|---------|
| P0 | `list-runs` + `fetch-run-logs` + `compute-flakiness` 三个采集原子 | 手动触发，验证 JSON 输出 |
| P0 | `data/known-issues.yml` 初始 seed（10 个常见模式） | 单元测试 grep 匹配 |
| P1 | `triage-failure.yml` 主流程（含 match-known-issues + classify-failure） | 在 1 个 repo 上运行 1 周 |
| P1 | `auto-rerun.yml` + throttle 逻辑 | 验证重跑计数和上限 |
| P2 | `health-daily.yml` + `detect-degradation` | 对比 2 周数据，验证退化检测 |
| P2 | Slack 通知集成 | 验证 critical/high 分级通知 |
| P3 | `health-weekly.yml` 深度分析 | 人工审查报告质量 |
| P3 | `heartbeat.yml` 自监控 | 模拟 triage-failure 停止运行 |
| P4 | 新 repo onboarding 流程 | 添加第 6 个 repo，验证零配置 |

---

## 十四、Onboarding 新仓库

新 repo 加入监控只需一步：

```yaml
# data/onboarded-repos.yml
repos:
  - name: org/repo-a
    workflows: "*"              # 监控所有 workflow
    priority: high              # high = 失败立刻通知, low = 只进报告

  - name: org/repo-b
    workflows: "pr.yml,ci.yml"  # 只监控指定 workflow
    priority: low

  - name: org/repo-c
    workflows: "*"
    priority: high
    exclude:
      - "stale.yml"             # 排除特定 workflow
      - "community.yml"
```

目标仓库不需要做任何配置变更。跨 repo 访问通过 fine-grained PAT 实现，该 PAT 只需 `actions:read` + `metadata:read` 权限。
