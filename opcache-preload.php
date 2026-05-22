<?php
// OPcache preload — précharge les fichiers core Nextcloud au démarrage PHP-FPM.
// Réduit la latence des premières requêtes après un redémarrage de container.
// Ignoré silencieusement si les volumes ne sont pas encore montés (premier boot).
$base = '/var/www/html';
if (!is_dir($base)) {
    return;
}

foreach (['/lib', '/core'] as $sub) {
    $dir = $base . $sub;
    if (!is_dir($dir)) {
        continue;
    }
    $iter = new RecursiveIteratorIterator(
        new RecursiveDirectoryIterator($dir, FilesystemIterator::SKIP_DOTS)
    );
    foreach ($iter as $file) {
        if ($file->isFile() && $file->getExtension() === 'php') {
            @opcache_compile_file($file->getRealPath());
        }
    }
}
