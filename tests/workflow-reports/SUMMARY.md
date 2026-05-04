# Workflow 全局测试汇总报告

**测试日期:** 2026-05-04
**测试范围:** 24 个 GitHub Actions workflow 文件（13 顶层 + 11 reusable）
**测试方法:** 并发 subagent 静态分析（YAML 语法、actionlint、SHA 引用、secret/variable 映射、权限审查、caller 兼容性）

---

## 总体统计

| 指标 | 数量 |
|------|------|
| 测试文件总数 | 24 |
| PASS（无问题或仅 LOW/INFO） | 16 |
| PASS with WARNINGS（MEDIUM） | 6 |
| PASS with CRITICAL/HIGH | 2 |
| CRITICAL 问题 | 4 |
| HIGH 问题 | 8 |
| MEDIUM 问题 | 25+ |
| LOW/INFO 问题 | 30+ |

---

## CRITICAL 问题（必须立即修复）

### 1. deploy.yml: `image-digest` 未传递给 stg/prd job
- **影响:** deploy 步骤构建 `registry/owner/name@` + 空字符串，部署必定失败
- **修复:** 在 stg/prd job 的 `with:` 块中添加 `image-digest: ${{ ... }}`
- **关联:** reusable-stg.yml 和 reusable-prd.yml 的 `image-digest` 输入均无默认值

### 2. deploy.yml: `stg-image-digest` 和 `stg-deploy-time` 未传递给 prd job
- **影响:** 生产环境的 observe-window 安全门控失效，可能在 staging 未验证的情况下直接部署生产
- **修复:** 在 prd job 的 `with:` 块中添加这两个输入

### 3. deploy.yml: SSH key secrets 未转发
- **影响:** `ssh-key-stg` 和 `ssh-key-prd` 未在 `secrets:` 块中传递，docker deploy（默认模式）的 preflight 会失败
- **修复:** 在 stg/prd job 的 `secrets:` 块中添加 SSH key 映射

### 4. deploy.yml: `kubeconfig-prd` 未传递
- **影响:** k8s 部署模式会失败
- **修复:** 在 prd job 的 `secrets:` 块中添加 `kubeconfig-prd`

---

## HIGH 问题（应该修复）

### 5. reusable-observability.yml: 死代码路径
- `schedule`、`workflow_dispatch`、`workflow_run` 事件检查在 `workflow_call` 上下文中不可达
- 仅 `workflow_call && inputs.mode == '...'` 分支是活跃的

### 6. reusable-observability.yml: `verify-fix` 引用未定义变量
- `github.event.workflow_run.head_sha` 在 `workflow_call` 上下文中未定义
- 需要添加 `head-sha` input 来桥接

### 7. reusable-stg.yml: `image-digest` 标记为 `required: false` 但无条件使用
- 应改为 `required: true` 或添加条件守卫

### 8. on-main-bump-sha.yml: `git add` 遗漏 `actions/` 目录
- bump 脚本更新 `.github/workflows/` 和 `actions/` 中的文件，但 `git add` 只暂存 `manifest.yml .github/workflows/`
- `actions/` 目录的更改会丢失

### 9. on-main-bump-sha.yml: SHA 不一致风险
- check step 使用 `git rev-parse HEAD`，但 bump 脚本独立 fetch `origin/main`
- 可能解析到不同的 SHA

### 10. reusable-release.yml: caller SHA 过时
- `f62931bd` 可能落后于文件最后修改的 commit

### 11. agent.yml: concurrency group 包含 `run_id`
- `cancel-in-progress` 守卫实际上无效（每次 run_id 都唯一）

### 12. reusable-agent.yml: 7 个 secret 声明但从未引用
- caller 提供的值静默丢弃

---

## MEDIUM 问题汇总

| Workflow | 问题 |
|----------|------|
| reusable-ci.yml | `MIGN_RESULT` 拼写错误（应为 `MIGRATION_RESULT`） |
| reusable-ci.yml | `generate-sbom` 是 stub，输出未被消费 |
| reusable-prd.yml | caller 缺少 `ssh-key-prd` secret |
| reusable-prd.yml | caller 缺少 `image-digest` input |
| reusable-prd.yml | 关键输入无默认值，导致静默失败 |
| reusable-prd.yml | ref 解析步骤在 11 个 job 中重复 |
| ci-self-test.yml | `security-events: write` 权限未使用 |
| on-maintenance.yml | 重复的 ref 解析逻辑 |
| on-maintenance.yml | `packages: read` 权限未使用 |
| on-main-bump-sha.yml | 无并发控制，可能创建重复 PR |
| release.yml | `attestations: write` 未使用（曾导致 startup_failure） |
| reusable-docs.yml | `bash -c` 缺少 `set -euo pipefail` |
| reusable-docs.yml | `always()` 可能导致 detect 失败时仍执行 deploy |
| observability.yml | `workflow_dispatch` 默认模式触发空操作 |
| reusable-pr.yml | `execute` job ref 解析逻辑与其他 job 不一致 |
| docs.yml | 版本注释与 manifest 不匹配 |
| reusable-maintenance.yml | `snyk-token` 声明但未使用 |
| dependencies.yml | manifest 路径引用错误（`deps.yml` vs `reusable-deps.yml`） |
| reusable-observability.yml | 无 `outputs:` 定义 |
| deploy.yml | runner 标签在 4 处硬编码 |

---

## 按严重程度分类的修复优先级

### P0 - 立即修复（部署流程断裂）
1. `deploy.yml`: 传递 `image-digest`、`stg-image-digest`、`stg-deploy-time`
2. `deploy.yml`: 转发 `ssh-key-stg`、`ssh-key-prd`、`kubeconfig-prd` secrets
3. `reusable-stg.yml`: 将 `image-digest` 改为 `required: true`

### P1 - 本周修复（功能缺陷）
4. `reusable-observability.yml`: 添加 `head-sha` input，清理死代码
5. `on-main-bump-sha.yml`: 修复 `git add` 遗漏 `actions/` 目录
6. `agent.yml`: 修复 concurrency group（移除 `run_id`）
7. `reusable-agent.yml`: 清理未使用的 secret 声明

### P2 - 下次迭代（代码质量）
8. 拼写错误修复（`MIGN_RESULT`）
9. 权限最小化（移除未使用的 permissions）
10. 注释与实际匹配
11. 并发控制添加

---

## 测试覆盖

每个 workflow 的详细测试报告位于 `tests/workflow-reports/` 目录：
- 25 个独立报告文件（每个 workflow 一个）
- 每个报告包含：Overview、Node-by-Node Status、Issues Found、Test Cases for Automation
- 总计 300+ 个自动化测试用例定义

---

## 自动化测试建议

后续可将测试报告中的 Test Cases 转换为：
1. **BATS 测试** — 验证 YAML 语法、SHA 引用、文件存在性
2. **actionlint CI job** — 在 PR 中自动检查 workflow 语法
3. **SHA 一致性检查** — 扩展 `verify-sha-consistency.sh` 覆盖所有 workflow
4. **Secret 映射验证** — 新增检查 caller 传递的 secret 是否匹配 reusable 定义
5. **Input 必填验证** — 检查 `required: false` 但无条件使用的 input
