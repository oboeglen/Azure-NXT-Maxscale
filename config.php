<?php
$CONFIG = array (
  'htaccess.RewriteBase' => '/',
  'upgrade.disable-web' => true,
  
  # Stockage S3
  'objectstore' =>
  array (
    'class' => '\\OC\\Files\\ObjectStore\\S3',
    'arguments' =>
    array (
      'bucket' => 'nextcloud',
      'autocreate' => false,
      'hostname' => 'IP',
      'key' => '=',
      'secret' => '=',
      'port' => 9000,
      'use_path_style' => true,
      'use_ssl' => false,
    ),
  ),

  # Redis Configuration
  'memcache.local' => '\\OC\\Memcache\\APCu',
  'memcache.distributed' => '\\OC\\Memcache\\Redis',
  'memcache.locking' => '\\OC\\Memcache\\Redis',
  'filelocking.enabled' => true,
  'filelocking.ttl' => 3600,
  'redis.cluster' =>
  array (
    'seeds' =>
    array (
      0 => '192.168.0.X:7001',
      1 => '192.168.0.X:7002',
      2 => '192.168.0.X:7003',
      3 => '192.168.0.X:7004',
      4 => '192.168.0.X:7005',
      5 => '192.168.0.X:7006',
    ),
    'failover_mode' => 1,
    'timeout' => 0.0,
    'read_timeout' => 0.0,
    'password' => 'pass',
  ),

  # Domaines autorisés
  'trusted_domains' =>
  array (
    0 => 'DOMAIN',
  ),
  'trusted_proxies' =>
  array (
    0 => 'IP',
  ),
  'overwrite.cli.url' => 'https://',
  'overwriteprotocol' => 'https',
  'overwritecondaddr' => '^192\\.168\\.X\\.X$',
  'datadirectory' => '/var/www/html/data',
  'forwarded-for-headers' =>
  array (
    0 => 'X-Forwarded-For',
    1 => 'HTTP_X_FORWARDED_FOR',
  ),
  
  # MariaDB Configuration
  'dbtype' => 'mysql',
  'dbname' => 'db_name',
  'dbhost' => 'db_host',
  'dbport' => '',
  'dbtableprefix' => 'oc_',
  'mysql.utf8mb4' => true,
  'dbuser' => 'db_user',
  'dbpassword' => 'db_password',

  # Paramètres Nextcloud
  'default_language' => 'fr',
  'force_language' => 'fr',
  'default_locale' => 'fr_FR',
  'default_phone_region' => 'FR',
  'force_locale' => 'fr_FR',
  'knowledgebaseenabled' => false,
  'allow_user_to_change_display_name' => false,
  'auth.webauthn.enabled' => false,
  'session_lifetime' => 86400,
  'session_keepalive' => true,
  'auto_logout' => true,
  'remember_login_cookie_lifetime' => 1296000,
  'auth.bruteforce.protection.enabled' => true,
  'skeletondirectory' => '',
  'updater.release.channel' => 'stable',
  'maintenance' => false,
  'theme' => '',

  # Configuration Logs
  'mail_smtpmode' => 'smtp',
  'mail_smtphost' => 'host',
  'mail_smtpport' => 'port',
  'mail_sendmailmode' => 'smtp',
  'mail_smtpauth' => 1,
  'mail_smtpname' => 'email',
  'mail_smtppassword' => 'pass',
  'mail_from_address' => 'email',
  'mail_domain' => 'domain',
  'loglevel' => 0,
  'maintenance_window_start' => 1,
);
