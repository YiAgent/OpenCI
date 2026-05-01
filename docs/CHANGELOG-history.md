# OpenCI SPEC 历史变更日志

当前版本变更见 `docs/SPEC.md` 顶部"变更日志"段。本文件仅保存归档版本的历史记录。

| 版本 | 变更内容 |
| --- | --- |
| v1.6 | **P0 修复**：修复 read-manifest 架构缺陷(uses 必须是编译时常量)→改为直接写 SHA + CI 验证；修复 manifest.yml SHA 格式错误(全部 40 位 hex)；补全 manifest.yml 缺失的 8 个 action；修复 ai-triage JSON 注入风险(jq -n --arg)；修复 claude-harness 调用架构矛盾(拆为 composite + reusable 两层)；修复第九章子节编号(7.x→9.x)；删除 L2484 游离文本。**P1 整合**：Concurrency Groups 集成到所有工作流；Secrets Preflight 集成到所有工作流；graceful-skip 模式(scan-snyk/scan-sonarcloud)；修复 prd.yml 缺少 run-migration input；统一仓库名为 openCI；明确 prompt-path 参数链；修复 health-report.yml outputs 引用；修复 notify-deploy secrets 传递(env→with)；修复 16.4 与 7.8 重复。**P2 改进**：添加 timeout-minutes 到所有 job；添加 workflow_dispatch 触发器(stg/prd)；修复 community.yml 触发范围；修复 Codecov/SonarCloud 表格；添加 observe-window sleep 说明；Health Report collect-all 改为并行(matrix)；添加 prd.yml 回滚策略；替换 actions/stale 为 stale-org/stale；添加 MegaLinter flavor 映射说明；新增缺失工作流规格(docs-build/docs-deploy/release-docker)；新增成本估算章节；新增 EvolveCI 关系说明；新增 CHANGELOG 非 PR 变更说明；新增十八章(测试策略)；新增附录 C(测试策略) |
| v1.5 | 可观测性架构重构：拆分 push(deployment marker)与 pull(health report)模式；新增 actions/observability/ 目录（collect-synthesize-publish 三阶段）；新增 health-report.yml 工作流；新增十七章(GitHub 原生模板与仓库约定:PR_TEMPLATE/CODEOWNERS/labeler/auto-assign/dependabot/security.txt)；integrations/ 扩展 datadog-event/langsmith-tag/axiom-event/notify-deploy |
| v1.4 | Aicert 对比分析：新增十六章（29 项差距）；可观测性双目标设计：actions/integrations/(部署后推送 5 原子+notify-deploy composite) + actions/observability/(定时采集 5 原子+collect-all+publish-report+health-report workflow)；section 十七(GitHub 原生模板与仓库约定) |
| v1.3 | Action Marketplace 升级审计：补全 manifest.yml 缺失 action；新增 dependency-review-action、trivy-action、semantic-pull-request、paths-filter；linter 升级为 MegaLinter 多语言统一方案；淘汰 semgrep-action/vercel-action；新增六(Issue 管理体系)、七(外部服务集成:Sentry/SonarCloud/PostHog/Slack/Snyk/Linear)、十一(MegaLinter)、十二(容器安全扫描)章节；pr.yml 扩展 SonarCloud + PR 描述校验；prd.yml 扩展 Sentry release + PostHog 事件 + check-error-rate |
| v1.2 | 合并 v1.0 简洁哲学与 v1.1 实施细节；原则部分回归 prose-first 表达；保留全部 v1.1 实施规格、manifest、pre-check、附录 |
| v1.1 | 新增 Action Manifest 注册表；语言检测单一来源；市场服务深度集成（Codecov / CodeQL / harden-runner）；STG→PRD 强化 pre-check（版本对齐 + 观察窗口）；可观测性 annotation 规范 |
| v1.0 | 初始版本：三层架构 + 四条设计原则 |
