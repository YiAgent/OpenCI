## 变更内容
<!-- 简述这个 PR 做了什么。如果改动跨多个工作流 / action,逐项列出。 -->

## 关联 Issue
<!-- "Closes #N" 让合并时自动关闭对应 issue。无关联也请简述背景。 -->
Closes #

## 变更类型
- [ ] Bug fix
- [ ] New feature
- [ ] Breaking change(消费方需要调整 `uses:` 或 `with:`)
- [ ] Docs update
- [ ] Chore / 仓库元文件
- [ ] CI / 工作流变更
- [ ] 安全相关(SHA 升级、权限收紧等)

## 测试方法
<!--
请说明本 PR 如何验证。最少包括:
  1. 哪些 bats / e2e 测试覆盖了改动
  2. 如果是 workflow 变更,在哪个 e2e 仓库 / 分支跑过(贴 run URL)
  3. 是否需要消费方做迁移说明
-->

## Checklist
- [ ] `bats tests/` 全绿
- [ ] `bash .github/scripts/verify-sha-consistency.sh` 通过
- [ ] 新增 / 修改 workflow 的 SHA 已在 `manifest.yml` 登记
- [ ] 修改了 SPEC 中提及的输入 / 输出契约时,`docs/SPEC.md` 已同步更新
- [ ] 新增 action / script 的 bats 覆盖率 ≥ 80%
- [ ] 不在 `manifest-pending.yml` 的依赖中引用未验证 SHA
