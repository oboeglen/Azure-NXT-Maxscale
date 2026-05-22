# Politique de sécurité

## Versions supportées

| Version | Support sécurité |
|---------|:----------------:|
| 2.1.x (latest) | ✅ |
| 2.0.x | ⚠️ Mise à jour recommandée |
| < 2.0 | ❌ |

Seule la dernière version stable reçoit des correctifs de sécurité. Il est recommandé de toujours déployer depuis `main` ou la dernière release.

---

## Signaler une vulnérabilité

> [!IMPORTANT]
> **Ne pas ouvrir d'issue publique pour signaler une vulnérabilité.** Une divulgation publique prématurée expose les utilisateurs avant qu'un correctif soit disponible.

### Méthode préférée — GitHub Private Vulnerability Reporting

Utilisez la fonctionnalité de signalement privé de GitHub :

**[Signaler une vulnérabilité](https://github.com/oboeglen/Azure-NXT-Maxscale/security/advisories/new)**

Vous recevrez un accusé de réception dans les **48 heures**.

### Informations à inclure

Pour accélérer le traitement, précisez :

- **Version concernée** — tag ou commit hash
- **Composant** — `deploy.sh`, `haproxy.cfg`, `nextcloud-init.sh`, etc.
- **Description** — nature de la vulnérabilité et impact potentiel
- **Reproduction** — étapes minimales pour reproduire
- **Correctif suggéré** — si vous en avez un (optionnel)

---

## Délais de réponse

| Étape | Délai |
|-------|-------|
| Accusé de réception | 48 h |
| Évaluation et classification | 5 jours ouvrés |
| Correctif (critique / haute) | 14 jours |
| Correctif (moyenne / faible) | 30 jours |
| Publication de l'advisory | Après déploiement du correctif |

---

## Périmètre

### Dans le périmètre ✅

- `deploy.sh` — génération de secrets, gestion des permissions, logique de déploiement
- `haproxy.cfg` — règles de filtrage, configuration TLS, headers de sécurité
- `nextcloud-init.sh` — configuration post-installation, gestion des credentials
- `docker-compose.yml` / templates générés — exposition de ports, montages de volumes
- `nextcloud-custom.config.php` — configuration Nextcloud sensible
- Toute configuration qui exposerait des données utilisateur ou permettrait un accès non autorisé

### Hors périmètre ❌

- Vulnérabilités dans les images Docker upstream (`nextcloud`, `haproxy`, `collabora/code`, `redis`, `minio/minio`…) — signaler directement aux éditeurs concernés
- Vulnérabilités dans Nextcloud lui-même — [Nextcloud Security](https://nextcloud.com/security/)
- Vulnérabilités dans Collabora CODE — [Collabora Security](https://www.collaboraonline.com/security/)
- Configuration spécifique à l'environnement de l'utilisateur (mots de passe faibles, DNS mal configuré…)

---

## Mesures de sécurité en place

Ce projet intègre nativement les protections suivantes :

| Couche | Mesure |
|--------|--------|
| **Transport** | TLS 1.2 minimum, TLS 1.3 préféré, `no-tls-tickets` (PFS) |
| **HSTS** | `max-age=63072000; includeSubDomains; preload` |
| **Headers HTTP** | XCTO, XSS-Protection, Referrer-Policy, X-Frame-Options, Permissions-Policy |
| **CSP** | Nonce Nextcloud 33 + WebSocket Collabora/Whiteboard |
| **Méthodes** | TRACE/DEBUG/CONNECT bloquées, WebDAV restreint aux paths API |
| **Scanners** | User-agents malveillants et paths de scan courants bloqués (403) |
| **Collabora** | Console d'administration inaccessible depuis l'extérieur |
| **Secrets** | Générés aléatoirement via `openssl rand`, sans caractère `#` |
| **Réseau** | Isolation par réseau Docker dédié par service |
| **Logs** | Health checks silencés, version HAProxy masquée |

---

## Divulgation coordonnée

Une fois le correctif déployé dans une release, un **GitHub Security Advisory** sera publié avec :
- La description de la vulnérabilité
- Les versions affectées
- Les mesures de mitigation
- Le crédit au rapporteur (sauf demande d'anonymat)

Merci de contribuer à la sécurité de ce projet.
