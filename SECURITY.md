# Security Policy

## Supported versions

| Version | Security support |
|---------|:----------------:|
| 2.7.x (latest) | ✅ |
| 2.6.x | ⚠️ Update recommended |
| < 2.6 | ❌ |

Only the latest stable version receives security patches. It is recommended to always deploy from `main` or the latest release.

---

## Reporting a vulnerability

> [!IMPORTANT]
> **Do not open a public issue to report a vulnerability.** Premature public disclosure exposes users before a fix is available.

### Preferred method — GitHub Private Vulnerability Reporting

Use GitHub's private reporting feature:

**[Report a vulnerability](https://github.com/oboeglen/Azure-NXT-Maxscale/security/advisories/new)**

You will receive an acknowledgment within **48 hours**.

### Information to include

To speed up processing, please specify:

- **Affected version** — tag or commit hash
- **Component** — `deploy.sh`, `haproxy.cfg`, `nextcloud-init.sh`, etc.
- **Description** — nature of the vulnerability and potential impact
- **Reproduction** — minimal steps to reproduce
- **Suggested fix** — if you have one (optional)

---

## Response timeline

| Step | Timeline |
|------|----------|
| Acknowledgment | 48 h |
| Assessment and classification | 5 business days |
| Fix (critical / high) | 14 days |
| Fix (medium / low) | 30 days |
| Advisory publication | After fix deployment |

---

## Scope

### In scope ✅

- `deploy.sh` — secret generation, permission management, deployment logic
- `haproxy.cfg` — filtering rules, TLS configuration, security headers
- `nextcloud-init.sh` — post-installation configuration, credential management
- `docker-compose.yml` / generated templates — port exposure, volume mounts
- `nextcloud-custom.config.php` — sensitive Nextcloud configuration
- Any configuration that would expose user data or allow unauthorized access

### Out of scope ❌

- Vulnerabilities in upstream Docker images (`nextcloud`, `haproxy`, `collabora/code`, `redis`, `rustfs/rustfs`…) — report directly to the relevant publishers
- Vulnerabilities in Nextcloud itself — [Nextcloud Security](https://nextcloud.com/security/)
- Vulnerabilities in Collabora CODE — [Collabora Security](https://www.collaboraonline.com/security/)
- Configuration specific to the user's environment (weak passwords, misconfigured DNS…)

---

## Security measures in place

This project natively integrates the following protections:

| Layer | Measure |
|-------|---------|
| **Transport** | TLS 1.2 minimum, TLS 1.3 preferred, `no-tls-tickets` (PFS) |
| **HSTS** | `max-age=63072000; includeSubDomains; preload` |
| **HTTP headers** | XCTO, XSS-Protection, Referrer-Policy, X-Frame-Options, Permissions-Policy |
| **CSP** | Nextcloud 33 nonce + Collabora/Whiteboard WebSocket |
| **Methods** | TRACE/DEBUG/CONNECT blocked, WebDAV restricted to API paths |
| **Scanners** | Malicious user-agents and common scan paths blocked (403) |
| **Collabora** | Administration console inaccessible from outside |
| **Secrets** | Randomly generated via `openssl rand`, without `#` character |
| **Network** | Isolation via dedicated Docker network per service |
| **Logs** | Health checks silenced, HAProxy version hidden |

---

## Coordinated disclosure

Once the fix is deployed in a release, a **GitHub Security Advisory** will be published with:
- The vulnerability description
- Affected versions
- Mitigation measures
- Credit to the reporter (unless anonymity is requested)

Thank you for contributing to the security of this project.
