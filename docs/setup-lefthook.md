# Setup: lefthook 本地 git hooks

`lefthook.yml` 提供了一组本地 git hook,目标是在 push 之前消灭约 90% 的 lint 类问题,既节省 CI runner 时间,也减少 reviewer 噪音。

> **本组件是可选的。** OpenCI 仓库本身启用,消费方默认 opt-out;按需启用。

## 安装

```bash
# 1. 安装 lefthook 二进制(macOS / Linux 均可)
brew install lefthook
# 或 npm 安装(项目本地)
npm install --save-dev lefthook

# 2. 在仓库内激活 hook(读取根目录的 lefthook.yml)
lefthook install
```

激活后,`.git/hooks/pre-commit` / `.git/hooks/commit-msg` / `.git/hooks/pre-push` 会变成 lefthook 的薄入口,后续每次执行 `git commit` / `git push` 都自动触发。

## 各 hook 行为

| 阶段 | 命令 | 失败行为 |
| --- | --- | --- |
| `pre-commit` | `guard-no-main-commit` | 直接 commit 到 `main`/`master` → 拒绝 |
| `pre-commit` | `guard-dotenv` | staged 包含 `.env*`(允许 `.env.example`) → 拒绝 |
| `pre-commit` | `guard-large-files` | staged 文件 >512KB → 拒绝(改用 Git LFS) |
| `pre-commit` | `shell-lint` | shellcheck 报错(若未安装则 notice 跳过) |
| `pre-commit` | `yaml-lint` | yamllint 报错(若未安装则 notice 跳过) |
| `pre-commit` | `bats-format` | bats 文件 shellcheck 警告(只警告) |
| `pre-commit` | `guard-secrets` | gitleaks 检出 secret(若未安装则 notice 跳过) |
| `commit-msg` | `conventional-commit` | subject 不符合 `<type>(scope)?: <subject>` → 拒绝 |
| `pre-push` | `bats` | `bats tests/scripts tests/actions` 失败 |
| `pre-push` | `verify-sha` | `verify-sha-consistency.sh` 失败 |

## 紧急 bypass

**强烈不建议**长期使用 bypass。以下方式按"临时性递增"排序:

```bash
# 跳过单次 hook(配合 release / hotfix 场景)
LEFTHOOK=0 git commit -m "..."
LEFTHOOK=0 git push

# 跳过单一阶段(只 commit-msg 不跑,其他照旧)
git commit --no-verify -m "..."
```

绕过 hook **不绕过 CI**。CI 会再次跑同样的 lint / verify-sha,结果会卡住 PR 合并。

## 卸载

```bash
lefthook uninstall
```

会移除 `.git/hooks/*` 中的 lefthook 入口,但保留 `lefthook.yml`(以便后续 `lefthook install` 重新启用)。

## 推荐安装的本地工具

部分 hook 在工具缺失时只发 `::notice` 跳过,补齐工具能让本地体验更接近 CI:

```bash
# macOS
brew install shellcheck yamllint bats-core gitleaks yq

# Linux (Debian/Ubuntu 示例)
sudo apt install shellcheck yamllint
brew install bats-core gitleaks yq   # 或对应二进制下载
```

## 与 CI 的关系

lefthook 是**早期反馈层**,不是 CI 替代品:

```
[本地编辑] → lefthook (pre-commit / commit-msg / pre-push)
                   ↓ 通过
[push 到 GitHub] → CI workflows (verify-sha-consistency / pr.yml / ...)
                   ↓ 通过
[合并]
```

任何 hook 检查同样会在 CI 里再跑一次,确保 bypass 不会把问题混进 main。
