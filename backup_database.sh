#!/bin/bash

# Variables
PRIMARY_NODE="mariadb-node1"  # Nom du nœud primaire (le nœud dont nous faisons le dump)
BACKUP_DIR="/backup/mariadb"   # Répertoire local pour sauvegarder le dump
DUMP_FILE="${BACKUP_DIR}/mariadb_dump_$(date +'%Y%m%d_%H%M%S').sql"  # Nom du fichier dump
MYSQL_USER="user"  # Nom d'utilisateur MySQL
MYSQL_PASSWORD="pass"  # Mot de passe MySQL
RETENTION_COUNT=3  # Nombre de fichiers de sauvegarde à conserver

# Couleurs pour les messages
YELLOW='\033[1;33m'
NC='\033[0m' # Pas de couleur

# Liste des nodes MariaDB sauf le primaire et compter leur nombre
NODES=$(docker ps --format '{{.Names}}' | grep 'mariadb-node' | grep -v "$PRIMARY_NODE")
NODE_COUNT=$(echo "$NODES" | wc -l)
EXPECTED_CLUSTER_SIZE=$((NODE_COUNT + 1))  # Ajouter 1 pour inclure le nœud primaire

# Arrêter tous les nodes sauf le primaire
echo -e "${YELLOW}Arrêt des nodes MariaDB sauf $PRIMARY_NODE...${NC}"
for NODE in $NODES; do
    echo -e "${YELLOW}Arrêt du node $NODE...${NC}"
    docker stop "$NODE" > /dev/null 2>&1
done

# Attendre 30 secondes avant de lancer le dump
echo -e "${YELLOW}Attente de 30 secondes avant de commencer le dump...${NC}"
sleep 30

# Créer le répertoire de sauvegarde s'il n'existe pas
mkdir -p "$BACKUP_DIR"

# Exécuter le dump SQL
echo -e "${YELLOW}Démarrage du dump SQL dans le conteneur Docker...${NC}"
docker exec $PRIMARY_NODE sh -c "mariadb-dump --single-transaction --flush-logs --routines --triggers --all-databases -u $MYSQL_USER --password='$MYSQL_PASSWORD'" > "$DUMP_FILE"

# Vérifier si le dump a réussi
if [ $? -eq 0 ]; then
    echo -e "${YELLOW}Dump SQL réussi. Le fichier est enregistré dans : $DUMP_FILE${NC}"
else
    echo -e "${YELLOW}Erreur lors du dump SQL.${NC}"
    exit 1
fi

# Afficher la taille du fichier dump
echo -e "${YELLOW}Taille du fichier dump : $(du -sh "$DUMP_FILE" | cut -f1)${NC}"

# Redémarrer les autres nodes
echo -e "${YELLOW}Redémarrage des nodes MariaDB arrêtés...${NC}"
for NODE in $NODES; do
    echo -e "${YELLOW}Redémarrage du node $NODE...${NC}"
    docker start "$NODE" > /dev/null 2>&1
    sleep 60  # Attendre 60 secondes avant de redémarrer le prochain node
done

# Exécuter la commande SQL pour vérifier la taille du cluster Galera
echo -e "${YELLOW}Exécution de la commande SHOW GLOBAL STATUS LIKE 'wsrep_cluster_size'; sur mariadb-node1...${NC}"

# Récupérer uniquement la valeur de wsrep_cluster_size sans en-tête
CLUSTER_SIZE=$(docker exec -u root mariadb-node1 mariadb -u "$MYSQL_USER" --password="$MYSQL_PASSWORD" -e "SHOW GLOBAL STATUS LIKE 'wsrep_cluster_size';" --batch --skip-column-names | awk '{print $2}')

# Vérifier si le nombre de nodes démarrés correspond à la taille du cluster
if [ "$CLUSTER_SIZE" -eq "$EXPECTED_CLUSTER_SIZE" ]; then
    echo -e "${YELLOW}Le cluster Galera est complet avec $CLUSTER_SIZE nodes actifs.${NC}"
else
    echo -e "${YELLOW}Erreur : la taille du cluster Galera est $CLUSTER_SIZE, mais $EXPECTED_CLUSTER_SIZE nodes sont attendus.${NC}"
fi

# Nettoyer les anciens fichiers de sauvegarde
echo -e "${YELLOW}Nettoyage des anciennes sauvegardes pour conserver seulement les $RETENTION_COUNT fichiers les plus récents...${NC}"
cd "$BACKUP_DIR"
ls -t mariadb_dump_*.sql | awk "NR>$RETENTION_COUNT" | xargs -r rm -f

# Attente de 30 secondes avant de finir le script
echo -e "${YELLOW}La sauvegarde est terminée. Le script se terminera dans 15 secondes.${NC}"
sleep 15
