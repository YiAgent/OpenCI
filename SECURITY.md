# Security Policy

## TL;DR (English)

Found a security issue? **Don't open a public issue.** Use GitHub's
[private vulnerability reporting](https://docs.github.com/code-security/security-advisories/guidance-on-reporting-and-writing/privately-reporting-a-security-vulnerability)
on this repository, or email `security@<replace-with-your-domain>`.
Initial response within 2 business days. Severe issues acknowledged
publicly only after a fix is available.

## 报告渠道

发现 OpenCI 的安全问题时,请**不要**开 public issue。我们提供两条优先级递减的渠道:

1. **首选** — GitHub 私有漏洞报告
   通过 https://github.com/YiWang24/OpenCI/security/advisories/new 提交。
   GitHub 会创建一条仅维护者可见的 advisory,跟进过程在那条 thread 完成。

2. **备选** — 安全邮箱
   `security@<replace-with-your-domain>`(消费方 fork OpenCI 时请替换为自己域名下的邮箱)。
   邮件请加密(可选 PGP key,公钥见同目录 `SECURITY-pgp-pubkey.asc` 一旦发布)。

## 响应时效

| 阶段 | 时效 |
| --- | --- |
| 收到报告 → 初步回复 | 工作日 48 小时 |
| 初步回复 → 风险评估完成 | 工作日 5 天 |
| 风险评估 → 修复发布 | 视严重度,P0 / P1 内 7 天,其余视 sprint |
| 修复发布 → 公开 advisory | ≥ 修复版本发布 7 天后(给消费方升级时间) |

P0 = 远程代码执行 / supply-chain 后门;P1 = 影响生产部署的可利用漏洞。

## CVE 与 advisory

OpenCI 使用 GitHub Security Advisories(GHSA)管理。修复发布后:

1. 维护者撰写 advisory 草稿,标注影响版本与修复 commit
2. 申请 CVE(若适用)
3. 发布 GHSA(以及对应 CVE)
4. 在 release notes 与 CHANGELOG 中链接 advisory

## 范围

以下属于报告范围:

- 任何允许绕过 `verify-sha-consistency` 的方法
- 任何使第三方 action 加载未在 `manifest.yml` 中验证 SHA 的路径
- workflow injection / OIDC token 滥用
- 暴露 secret(包括日志泄漏)
- 任何让 PR 作者在缺乏权限时执行 slash command 的路径
- supply chain 攻击(prompt injection 进入 AI step、fixture 投毒等)

以下**不在**范围内:

- 消费方仓库自身的配置错误(请联系消费方)
- 第三方 SaaS(Sentry / Datadog / PostHog 等)的产品安全 — 报给厂商
- DDoS / 速率限制类问题(GitHub Actions 平台问题,报给 GitHub)

## 致谢

我们欢迎并感谢负责任披露。报告者将在 advisory 与 CHANGELOG 中署名(若同意)。

不接受未经验证的"安全研究员"自动扫描结果(如未做去重的 trivy / nuclei 全网撒网式报告)。请先复现并写明利用路径。
