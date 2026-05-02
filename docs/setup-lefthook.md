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

激活后,`.git/hooks/pre-commit` / `.git/hooks/commit-msg` / `.git/hooks/pre-push` / `.git/hooks/post-merge` 会变成 lefthook 的薄入口,后续每次执行 `git commit` / `git push` / `git merge` 都自动触发。

> **更新提示:** `lefthook.yml` 变化后,`post-merge` 会打印 notice,提醒重新跑 `lefthook install`。

## 各 hook 行为

### `pre-commit` — 仅扫描 staged 文件,目标 <5s

| 命令 | tags | 失败行为 |
| --- | --- | --- |
| `guard-no-main-commit` | `guard` | 直接 commit 到 `main`/`master` → 拒绝 |
| `guard-dotenv` | `guard`, `security` | staged 包含 `.env*`(允许 `.env.example` / `.sample` / `.template`) → 拒绝 |
| `guard-large-files` | `guard` | staged 文件 >512KB → 拒绝(改用 Git LFS) |
| `guard-secrets` | `guard`, `security` | gitleaks 检出 secret(若未安装则 notice 跳过) |
| `forbid-unpinned-actions` | `lint`, `security` | staged YAML 出现 `@v1` / `@main` / 非 40 字符 SHA → 拒绝 |
| `shell-lint` | `lint` | shellcheck 报错(若未安装则 notice 跳过) |
| `shell-format` | `format` | `shfmt -i 2 -ci -s -w` 自动改写,改写后用 `stage_fixed` 重新 stage |
| `yaml-lint` | `lint` | yamllint 报错(若未安装则 notice 跳过) |
| `actionlint` | `lint` | 对 staged workflow / `action.yml` 跑 actionlint(若未安装则 notice 跳过) |
| `json-validate` | `lint` | jq 或 python3 解析失败 → 拒绝 |
| `bats-lint` | `lint` | `*.bats` 文件 shellcheck 报错(若未安装则跳过) |
| `eof-newline` | `format` | 文本文件缺少结尾换行 → 拒绝 |
| `verify-sha-when-manifest-changed` | `security` | 只在 `manifest*.yml` 或带 `uses:` 的文件被 stage 时运行 verify-sha |

### `commit-msg`

| 命令 | 失败行为 |
| --- | --- |
| `conventional-commit` | subject 不符合 `<type>(scope)?: <subject>` → 拒绝(`feat\|fix\|refactor\|docs\|test\|chore\|perf\|ci\|build\|style\|revert`) |
| `subject-length` | subject >72 字符 → 拒绝 |
| `body-line-length` | body 行 >100 字符 → 仅 warning,不拒绝 |

### `pre-push` — 仓库全量,目标 <30s

| 命令 | tags | 失败行为 |
| --- | --- | --- |
| `bats` | `test` | `bats tests/scripts tests/actions` 失败 |
| `verify-sha` | `security` | `verify-sha-consistency.sh` 失败 |
| `actionlint-full` | `lint` | 仓库范围 `actionlint` 失败 |
| `shellcheck-full` | `lint` | 全部 tracked `*.sh` 的 shellcheck 失败 |
| `yamllint-full` | `lint` | 仓库范围 `yamllint .` 失败 |

### `post-merge`

| 命令 | 行为 |
| --- | --- |
| `notify-lefthook-changed` | 若本次 merge 修改了 `lefthook.yml`,打印提示让你重新 `lefthook install`(永不阻塞) |

## 选择性运行 / 跳过

`tags` 让你只跑或只跳一组检查:

```bash
# 只跑 security 类(含 guard-dotenv / guard-secrets / forbid-unpinned / verify-sha)
lefthook run pre-commit --tags security

# 跑 pre-commit 但跳过所有 lint
lefthook run pre-commit --exclude-tags lint

# 临时跑 pre-push 的子集,跳过慢命令
lefthook run pre-push --exclude-tags lint
```

可用的 tag 集合:`guard`、`security`、`lint`、`format`、`test`。

## 紧急 bypass

**强烈不建议**长期使用 bypass。以下方式按"临时性递增"排序:

```bash
# 跳过单次该阶段(配合 release / hotfix 场景)
LEFTHOOK=0 git commit -m "..."
LEFTHOOK=0 git push

# 标准 git 旁路(仅当前阶段)
git commit --no-verify -m "..."
git push --no-verify

# 按命令名跳过(逗号分隔,匹配 lefthook.yml 中的 command 名)
LEFTHOOK_EXCLUDE=actionlint,shellcheck-full git push
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
brew install shellcheck shfmt yamllint actionlint bats-core gitleaks yq jq

# Linux (Debian/Ubuntu 示例)
sudo apt install shellcheck yamllint jq
brew install shfmt actionlint bats-core gitleaks yq   # 或对应二进制下载
```

工具与 hook 的对应:

| 工具 | 用于 |
| --- | --- |
| `shellcheck` | `shell-lint`, `bats-lint`, `shellcheck-full` |
| `shfmt` | `shell-format` |
| `yamllint` | `yaml-lint`, `yamllint-full` |
| `actionlint` | `actionlint`, `actionlint-full` |
| `gitleaks` | `guard-secrets` |
| `yq` | `verify-sha-when-manifest-changed`, `verify-sha` |
| `jq` 或 `python3` | `json-validate` |
| `bats` | `bats` (pre-push) |

## 与 CI 的关系

lefthook 是**早期反馈层**,不是 CI 替代品:

```text
[本地编辑] → lefthook (pre-commit / commit-msg / pre-push)
                   ↓ 通过
[push 到 GitHub] → CI workflows (verify-sha-consistency / pr.yml / ...)
                   ↓ 通过
[合并] → lefthook post-merge (提示 lefthook.yml 是否变化)
```

任何 hook 检查同样会在 CI 里再跑一次,确保 bypass 不会把问题混进 main。
