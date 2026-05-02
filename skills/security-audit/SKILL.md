---
name: security-audit
description: >
  Perform a comprehensive security audit of code changes or the full codebase.
  Combines Trail of Bits differential security review with ECC security checklist.
  Use when reviewing security-sensitive changes or conducting periodic audits.
triggers:
  - security audit
  - security review
  - vuln scan
  - security check
---

# Security Audit

You are performing a security audit on {{repo}}.

## Inputs

```json
{{context}}
```

`context` includes:
- `scope` — "diff" (PR changes only) | "full" (entire codebase)
- `diff` — unified diff (if scope=diff)
- `language` — primary language
- `framework` — web framework in use
- `has_auth` — true if auth-related code exists
- `has_db` — true if database operations exist
- `has_payments` — true if payment/financial code exists

## Audit Checklist

### 1. Secrets & Credentials

- [ ] No hardcoded API keys, passwords, tokens, or secrets
- [ ] No secrets in comments, debug logs, or error messages
- [ ] .env files not committed (check .gitignore)
- [ ] No secrets in CI/CD config files
- [ ] Environment variables validated at startup

### 2. Input Validation

- [ ] All user input validated at system boundaries
- [ ] Schema-based validation for structured input
- [ ] File upload: type, size, content validation
- [ ] URL/redirect validation (no open redirects)
- [ ] Request size limits configured

### 3. Injection Prevention

- [ ] SQL: parameterized queries only (no string concatenation)
- [ ] NoSQL: query operators sanitized ($gt, $ne, etc.)
- [ ] Command: no shell execution with user input
- [ ] LDAP/XPath/Template injection checked
- [ ] ORM queries don't allow raw SQL with user input

### 4. Authentication & Authorization

- [ ] Auth checks on all protected endpoints
- [ ] No IDOR (Insecure Direct Object Reference) vulnerabilities
- [ ] Session management: secure flags, expiration, rotation
- [ ] Password: hashed with bcrypt/argon2, salted
- [ ] MFA implementation follows standards
- [ ] JWT: validated signature, expiration, issuer, audience

### 5. XSS Prevention

- [ ] HTML output escaped (context-aware: HTML, JS, CSS, URL)
- [ ] Content-Security-Policy headers configured
- [ ] No `innerHTML` with user content
- [ ] Markdown rendering sanitized (no raw HTML injection)
- [ ] HTTPOnly and Secure flags on cookies

### 6. CSRF Protection

- [ ] CSRF tokens on all state-changing endpoints
- [ ] SameSite cookie attribute set
- [ ] Origin/Referer header validation

### 7. Rate Limiting & DoS

- [ ] Rate limiting on auth endpoints (login, register, reset)
- [ ] Rate limiting on expensive operations (search, export)
- [ ] Request body size limits
- [ ] No unbounded queries (pagination required)

### 8. Dependency Security

- [ ] No known CVEs in dependencies (check lock files)
- [ ] No unnecessary dependencies
- [ ] Dependencies pinned to specific versions
- [ ] No typosquatting risks (verify package names)

### 9. Cryptographic Practices

- [ ] No custom crypto (use standard libraries)
- [ ] TLS enforced (no HTTP for sensitive operations)
- [ ] Secure random for tokens/secrets (crypto.randomBytes, not Math.random)
- [ ] Correct algorithm choices (AES-256-GCM, not ECB)

### 10. Error Handling

- [ ] Error messages don't leak stack traces to users
- [ ] Internal errors logged server-side only
- [ ] Generic error responses for auth failures (no "user not found")
- [ ] No debug endpoints in production

## Blast Radius Assessment

For each finding, assess impact:
- **Critical**: full account takeover, data exfiltration, RCE
- **High**: partial data exposure, privilege escalation, auth bypass
- **Medium**: information disclosure, DoS, CSRF on non-critical endpoints
- **Low**: missing headers, verbose errors, minor misconfigurations

## Output

### Security Report

```markdown
### Findings

| # | Severity | Category | Location | Description |
|---|----------|----------|----------|-------------|
| 1 | CRITICAL | injection | file:line | ... |

### Recommendations
- Prioritized remediation steps with effort estimates

### Positive Observations
- Good practices already in place (encourage, don't just criticize)
```

## Rules

- CRITICAL findings block the PR — must fix before merge
- HIGH findings should fix before merge — warn with specific fix
- Always provide a fix suggestion, not just the problem
- Check OWASP Top 10 as baseline
- For full audits, prioritize public-facing endpoints first
