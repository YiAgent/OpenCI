# Contributing to OpenCI

> 中文为主,英文摘要在每节顶部。

## TL;DR (English)

OpenCI is a GitHub-Actions reusable workflow library with agentic AI
pipelines. Contribute via pull request: fork → branch → PR. Every change
must pass `bats tests/`, `bash .github/scripts/verify-sha-consistency.sh`,
and the PR-level checklist (see `.github/PULL_REQUEST_TEMPLATE.md`). Prefer
the smallest patch that solves the user-visible problem.

---

## 0. 文档先读

开始任何改动前请先看:

- [`docs/SPEC.md`](docs/SPEC.md) — 全仓库的契约。SPEC 与代码必须一一对应,改契约要同步改 SPEC。
- [`tasks/`](tasks/) — 实施计划与状态。每个任务自包含约束 + 验收标准,提交 PR 时同步更新对应任务的 Status。

## 1. 本地准备

```bash
# 必装(macOS 示例)
brew install yq bats-core jq shellcheck yamllint

# 推荐:本地 git hooks(catches ~90% of CI lint failures)
brew install lefthook
lefthook install
```

详见 [`docs/setup-lefthook.md`](docs/setup-lefthook.md)。Lefthook 是可选的,
不启用也不会被 CI 拒绝(但本地反馈会变慢)。

## 2. 工作流

```text
fork → 新分支(不允许直推 main)
     → 修改 + 写测试
     → bats tests/ 全绿
     → verify-sha-consistency.sh 通过
     → commit (Conventional Commits)
     → push + 开 PR
     → CI 全绿 + Code review
     → squash merge
```

### 分支命名

- `feat/<short-name>` — 新功能
- `fix/<short-name>` — bug 修复
- `chore/<short-name>` — 不影响运行时的杂活
- `docs/<short-name>` — 仅文档

### Commit message 格式 — Conventional Commits

```
<type>(<scope>)?: <subject>

<optional body>
```

Type 集合(与 lefthook commit-msg 校验保持一致):

`feat | fix | refactor | docs | test | chore | perf | ci | build | style | revert`

例:`feat(prd): add check-error-rate atom`、`fix(verify-sha): ignore lines from grep -n prefix`。

## 3. 测试要求

- **新增 shell action / 脚本** → 对应 `tests/{actions,scripts}/<name>.bats`,覆盖主路径 + 失败路径 + 边界。
- **新增 workflow** → 在 `openCI-e2e` 测试仓库加 `test-<workflow>.yml`(若存在)。
- **新增 AI skill** → 验证输出 schema 符合对应 `action-plan/v1` 规范。
- 合并前 `bats tests/` 与 `verify-sha-consistency` 必须绿。

## 4. SHA 单一来源

任何第三方 `uses:` 必须是 40 位 commit SHA,且与 `manifest.yml` 一致。
违反会被 `verify-sha-consistency` 阻断。新增依赖流程:

1. 在 `manifest-pending.yml` 写下未验证 SHA(占位符 `<待验证 SHA>` 或刚拿到的)
2. 按 [`docs/SPEC.md` §3.1](docs/SPEC.md) 的 checklist 验证
3. 通过后,**同一个 PR 内**:
   - 把条目从 `manifest-pending.yml` 移到 `manifest.yml`
   - 替换所有 workflow / action 文件中的占位符为真实 SHA

## 5. 调用层级单向

```
Reusable Workflow (reusable-*.yml)
  └── Composite Action (job ≙ composite, 一对一映射)
        └── 原子 Action (单一职责)
              └── 第三方 action (manifest.yml 中的 SHA)

AI 调用链:
  原子内 AI step → _common/claude-harness (composite)
  独立 AI job   → reusable-agent.yml (reusable workflow)
```

- Composite **不**调用 Composite。
- 原子 **不**互相调用。
- 主工作流 **不**直接调用原子(必须经 composite)。
- AI 调用统一通过 `claude-harness`,不直接调用 Claude API。

## 6. 安全 & 权限

- 每个 job 第一步 `step-security/harden-runner@<SHA>`,默认 `egress-policy: audit`。
- 每个 workflow 顶层 `permissions: {}`,job 级精确授权。
- secret **必须** via `secrets:` 段或 `with:` 显式传入,**不**走环境变量泄漏。

## 7. 上报问题

- **bug / feature**:开 GitHub issue,用对应模板。
- **安全漏洞**:**不**要开 public issue。按 [`SECURITY.md`](SECURITY.md) 走私下渠道。

## 8. 行为准则

参与本项目即同意遵守 [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md)。

## 9. 维护者联系

讨论入口请优先用 GitHub Discussions。技术细节通过 Issue / PR review。
