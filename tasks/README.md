# OpenCI 实施计划

本目录把 [`docs/SPEC.md`](../docs/SPEC.md) 附录 A 的 33 项实施任务展开为可执行单元。每个任务自包含,有明确**约束**(必须满足的设计规则)与**验收标准**(可观察、可命令验证的产物)。

## 文件索引

| 阶段 | 文件 | 任务数 | 阶段目标 |
| --- | --- | --- | --- |
| P0 | [P0.md](P0.md) | 7 | 基础设施与安全门(必备,任何使用 OpenCI 的前提) |
| P1 | [P1.md](P1.md) | 7 | 主链路:开发流可用(PR / CI / STG / PRD 端到端) |
| P2 | [P2.md](P2.md) | 7 | 完整流程:加入 pre-check / 可观测性 / 跨工作流聚合 |
| P3 | [P3.md](P3.md) | 6 | 辅助与生态:docs / community / stale / 仓库元文件 |
| P4 | [P4.md](P4.md) | 6 | Aicert 高级特性(按需引入,非必装) |

---

## 全局约束(GC)

每个任务都**必须**满足以下规则,文档中不重复罗列。任务自身只列**额外约束**。

### GC1 — SHA 固定(原则五)

- 所有第三方 `uses:` 必须是 **40 位 commit SHA**,严禁 `@v*` / `@main` / `@master`。
- SHA 在仓库各文件中的值必须与 `manifest.yml` 一致(`manifest-pending.yml` 中的条目**不可被引用**)。
- 引用的 action 不得出现在 `docs/SPEC.md` 附录 B.2(已淘汰)清单中。
- `verify-sha-consistency` CI job 会阻断违规 PR(见 P0-1)。

### GC2 — 调用层级单向(原则三)

```
主工作流 (reusable workflow, on: workflow_call)
  └── Composite Action (job ≙ composite, 一对一映射, 一个 job 只调一个 composite)
        └── 原子 Action (单一功能, 不互调)
              └── (AI 原子专属) → _common/claude-harness composite 或 claude-harness.yml reusable workflow
```

- Composite **不**调用其他 Composite。
- 原子 Action **不**互相调用。
- 主工作流 **不**直接调用原子(必须经过 Composite)。
- 一个 job **不**串接多个 composite。
- AI 调用判定:**调用是 step 中的一个动作 → composite**;**调用是整个 job → reusable workflow**。

### GC3 — 安全默认

- **每个 job** 第一步必须是 `step-security/harden-runner@<SHA>`,默认 `egress-policy: audit`。
- **每个 workflow** 顶层 `permissions: {}` 拒绝所有,**job 级别**精确授权(参考 SPEC 9.2 矩阵)。
- 认证优先 OIDC(`id-token: write`),避免长期凭证。
- 任何 secret **必须** via `secrets:` 段或 `with:` 显式传入,**不** via 环境变量泄漏。

### GC4 — 工作流标准结构

每个 reusable workflow 必须包含:

1. **触发**:`on: workflow_call:`(可叠加 `workflow_dispatch` / `schedule` / `push.tags`)
2. **`concurrency`** 块,group 表达式遵循 SPEC 5.7 节(`pr-${{ pr.number }}` / `ci-${{ github.ref }}` 等)
3. **`jobs.preflight`** 首个 job,通过 `bash .github/scripts/preflight-secrets.sh --required ... --optional ...` 校验 secret;其他 job `needs: preflight`
4. **每个 job** 显式 `timeout-minutes`(SPEC 5.x 各节给出基线值)
5. **每个 job** 显式 `permissions:`(最小化)

### GC5 — 可观测性 Annotation

关键步骤通过 stdout 输出 GitHub Actions annotation,格式见 SPEC 8.1。例:

```bash
echo "::notice title=Image Built::digest=$D size=${S}MB"
echo "::error title=Version Mismatch::prd=$P stg=$S"
```

### GC6 — 测试

- **新增 shell action** → 对应 `tests/actions/<name>.bats`,覆盖率 80%+(主路径 + 失败路径 + 边界)。
- **新增 workflow** → 在 `openCI-e2e` 测试仓库加 `test-<workflow>.yml`,触发后端到端验证。
- **新增 script** → `tests/scripts/<name>.bats`。
- 每个 action / workflow / script 在合并前 `bats tests/` 与 `verify-sha-consistency` 必须绿。

### GC7 — Annotation 与文档

- 修改 SPEC 中提及的 input/output 契约时,**必须**同步修改 SPEC.md 对应章节。
- 新增 action 必须在 `docs/SPEC.md` 第二章目录结构提及一次(高层概览即可)。

---

## 依赖图

```
P0-1 (manifest + verify-sha)  ← 所有任务的前置
   │
   ├─ P0-2 (detect-language)
   │     └─ P1-8 (pr.yml lint/test/scan)
   │           └─ P1-9 (claude-harness)
   │                 └─ 所有 AI 步骤(P1-8 review-ai / P1-10 eval-smoke / P3-22 ai-triage / P2-18 health-report / P4-32)
   │
   ├─ P0-3 (concurrency)       ← 集成到 P1-8/9/10/11/13、P2-15/16/18、P3-22/23
   ├─ P0-4 (preflight-secrets) ← 同上
   ├─ P0-5 (graceful-skip)     ← P1-8 (scan-snyk/sonarcloud)、P2-16 (security-schedule)
   ├─ P0-6 (PR Templates+CODEOWNERS)
   └─ P0-7 (lefthook 模板)

P1-8 (pr.yml)         → P1-10 (ci.yml,共用 detect-language) → P1-11 (stg.yml) → P1-13/14 (prd.yml) → P2-15 (prd 完整)
                                                                                                        └─ P2-17 (notify-deploy)
                                                                                                        └─ P2-18 (health-report)
P1-12 (observe-window 迁移) ← 替换 P1-13 中临时 sleep 实现

P2-19 (workflow_run 聚合) ← 在 P1-8/10/11/13 全部就绪后

P3-22..27 ← 大部分独立,P3-22 issue triage 依赖 P1-9 (claude-harness)

P4 各项独立,大多依赖 P3-22 / P1-9 已就绪
```

---

## 任务编号约定

`<P>-<N>`:`P` 是阶段(P0–P4),`N` 是 SPEC 附录 A 的全局序号(1–33)。如 `P0-3` = P0 阶段的第 3 项(Concurrency Groups 全覆盖)。

## 任务状态约定

每个任务顶部有状态标记,合并 PR 时同步更新:

```
**Status**: 🔴 Not Started | 🟡 In Progress | 🟢 Done | ⚪ Blocked
```

阻塞任务必须在标题下注明阻塞原因与解除条件。
