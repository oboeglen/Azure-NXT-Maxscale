-- Utilisateur pour les health-checks HAProxy (pas de mot de passe requis)
CREATE USER IF NOT EXISTS 'haproxy_check'@'%';
FLUSH PRIVILEGES;
