#!/bin/bash
# =============================================================================
# galera-bootstrap.sh — Entrypoint sécurisé pour mariadb-node1
# Bootstrap le cluster uniquement si safe_to_bootstrap=1 ou premier démarrage.
# Évite de créer un nouveau cluster si node1 redémarre alors que d'autres
# nœuds sont déjà en ligne (risque de split-brain avec --wsrep-new-cluster fixe).
# =============================================================================
GSTATE="/var/lib/mysql/grastate.dat"

if [ ! -f "$GSTATE" ] || grep -qs "safe_to_bootstrap: 1" "$GSTATE"; then
    echo "[galera] Bootstrap — safe_to_bootstrap=1 ou premier démarrage"
    exec docker-entrypoint.sh mysqld --wsrep-new-cluster
else
    echo "[galera] Rejoindre le cluster (safe_to_bootstrap=0)"
    exec docker-entrypoint.sh mysqld
fi
