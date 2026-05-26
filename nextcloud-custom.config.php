<?php
// =============================================================================
// nextcloud-custom.config.php — Config permanente chargée avant nextcloud-init.sh
// Monté en :ro dans tous les containers Nextcloud (app, setup, cron).
// Nextcloud charge automatiquement tous les .php du dossier config/.
// =============================================================================
$CONFIG = [
  // Autorise Nextcloud à contacter sa propre URL interne (IPs Docker 172.x.x.x)
  // Requis pour que le check /.well-known/caldav réussisse depuis le container
  'allow_local_remote_servers' => true,

  // SSL terminé par HAProxy — forcer HTTPS dans les URLs générées par Nextcloud
  'overwriteprotocol' => 'https',

  // Niveau de log : 3 = Erreur uniquement (supprime les Avertissements PHP)
  // 0=Débogage 1=Info 2=Avertissement 3=Erreur 4=Fatal
  'loglevel' => 3,

  // HAProxy fait des health checks fréquents qui déclenchent le brute force
  // et le rate limiting dès le premier déploiement — désactivés car la
  // protection réelle est assurée par HAProxy en amont.
  'auth.bruteforce.protection.enabled' => false,
  'ratelimit.protection.enabled' => false,
];
