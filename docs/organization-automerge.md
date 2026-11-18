# YiAgent PR 自动合并

2026-11-18，组织维护者授权所有仓库的 PR 自动合并，替代 Mergify。入口为 `organization-automerge.yml`，每 5 分钟巡检；GitHub 定时触发可能延迟。使用专用 `YIAGENT_MERGE_TOKEN`（来自维护者既有 GitHub CLI 授权；原 GH_TOKEN 的首次只读身份验证返回 401，未复用），不调用模型，不检出或执行被扫描 PR 的代码；仅读取仓库与 PR 元数据。GitHub Actions 日志和摘要保留逐条决策及合并 SHA。

启用：仓库变量 `YIAGENT_AUTOMERGE_ENABLED=true`。暂停：改为 `false`；此时仍只读巡检。手动触发默认 `dry-run=true`。运行时动态列出 YiAgent 的当前仓库，归档仓库跳过。trade 由自己的 `Automatic PR merge` 执行器处理，组织执行器跳过它，避免两个写者。

条件：目标为默认分支、非草稿、同仓库分支、无冲突、没有 hold/do-not-merge/blocked/wip 标签、没有要求修改的评审或未解决讨论，当前 head 至少有一项成功的 Actions CI；全部最新 check、commit status 和 PR/push workflow run 均结束且成功、neutral 或按路径跳过。只按 Mergify App 身份排除已退役检查，其他同名失败仍阻塞。leader 和 zhituo 保留原具名 CI 与 GitGuardian 必需检查。其他仓库沿用现有检查集合。

合并使用已验证的 head SHA；leader 使用 merge commit，便于已有工作树祖先检查，其余使用 squash。写入后读取 `merged` 和 merge SHA；结果不明不重发，暂停该仓库本轮后续操作。跨仓库 PAT 合并会正常触发原 CI/CD；本流程不另行提升生产、重启服务或发布内容。Pengli 只处理已在 GitHub 的 PR 元数据，不上传本机客户文件。

GitHub Free 私有仓库没有服务端分支保护，此执行器约束自身行为，不改变开发者已有手工写权限。凭据失效或读取权限不足时只报告失败，不当作无 PR。恢复 Mergify 配置可回退各仓库的移除提交；恢复 App 须由组织管理员重新安装。
