<?php
// =============================================================================
// nextcloud-custom.config.php — Config permanente chargée avant nextcloud-init.sh
// Monté en :ro dans tous les containers Nextcloud (app, setup, cron).
// Nextcloud charge automatiquement tous les .php du dossier config/.
// =============================================================================
$CONFIG = [
  // Identifiant unique par nœud PHP — requis pour les clusters multi-instances.
  // gethostname() retourne le hostname Docker du container (défini via hostname: dans compose).
  'serverid' => gethostname(),

  // Autorise Nextcloud à contacter sa propre URL interne (IPs Docker 172.x.x.x)
  // Requis pour que le check /.well-known/caldav réussisse depuis le container
  'allow_local_remote_servers' => true,

  // SSL terminé par HAProxy — forcer HTTPS dans les URLs générées par Nextcloud
  'overwriteprotocol' => 'https',

  // Niveau de log : 3 = Erreur uniquement (supprime les Avertissements PHP)
  // 0=Débogage 1=Info 2=Avertissement 3=Erreur 4=Fatal
  'loglevel' => 3,

  // Sans trusted_proxies, Nextcloud voit toutes les requêtes comme venant de
  // l'IP HAProxy — health checks + logins partagent le même compteur brute force.
  // Avec ces CIDRs, Nextcloud utilise X-Forwarded-For → chaque client a son propre
  // compteur. Les subnets couvrent les 6 réseaux Docker définis dans docker-compose.
  'trusted_proxies' =>
    ['172.10.0.0/24', '172.20.0.0/24', '172.30.0.0/24',
     '172.40.0.0/24', '172.50.0.0/24', '172.100.0.0/24'],
];
