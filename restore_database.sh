#!/bin/bash

# Variables
PRIMARY_NODE="mariadb-node1"  # Nom du nœud primaire (le nœud sur lequel nous restaurons la base de données)
BACKUP_DIR="/backup/mariadb"   # Répertoire local où sont stockées les sauvegardes
MYSQL_USER="user"  # Nom d'utilisateur MySQL
MYSQL_PASSWORD="pass"  # Mot de passe MySQL

# Couleurs pour les messages
YELLOW='\033[1;33m'
NC='\033[0m' # Pas de couleur

# Liste des nodes MariaDB sauf le primaire
NODES=$(docker ps --format '{{.Names}}' | grep 'mariadb-node' | grep -v "$PRIMARY_NODE")

# Trouver le fichier SQL le plus récent
LATEST_DUMP=$(ls -t ${BACKUP_DIR}/mariadb_dump_*.sql | head -n 1)

if [ -z "$LATEST_DUMP" ]; then
    echo -e "${YELLOW}Aucun fichier de sauvegarde trouvé dans $BACKUP_DIR.${NC}"
    exit 1
fi

# Arrêter tous les nodes sauf le primaire
echo -e "${YELLOW}Arrêt des nodes MariaDB sauf $PRIMARY_NODE...${NC}"
for NODE in $NODES; do
    echo -e "${YELLOW}Arrêt du node $NODE...${NC}"
    docker stop "$NODE" > /dev/null 2>&1
done

# Attendre 30 secondes avant de lancer la restauration
echo -e "${YELLOW}Attente de 30 secondes avant de commencer la restauration...${NC}"
sleep 30

# Restaurer la base de données
echo -e "${YELLOW}Démarrage de la restauration de la base de données dans le conteneur Docker...${NC}"
docker exec -i $PRIMARY_NODE sh -c "mariadb -u $MYSQL_USER --password='$MYSQL_PASSWORD'" < "$LATEST_DUMP"

# Vérifier si la restauration a réussi
if [ $? -eq 0 ]; then
    echo -e "${YELLOW}Restauration réussie à partir de : $LATEST_DUMP${NC}"
else
    echo -e "${YELLOW}Erreur lors de la restauration de la base de données.${NC}"
    exit 1
fi

# Redémarrer les autres nodes
echo -e "${YELLOW}Redémarrage des nodes MariaDB arrêtés...${NC}"
for NODE in $NODES; do
    echo -e "${YELLOW}Redémarrage du node $NODE...${NC}"
    docker start "$NODE" > /dev/null 2>&1
    sleep 60  # Attendre 1 minute avant de redémarrer le prochain node
done

# Exécuter la commande SQL pour vérifier la taille du cluster Galera
echo -e "${YELLOW}Exécution de la commande SHOW GLOBAL STATUS LIKE 'wsrep_cluster_size'; sur mariadb-node1...${NC}"

# Récupérer uniquement la valeur de wsrep_cluster_size sans en-tête
CLUSTER_SIZE=$(docker exec -u root mariadb-node1 mariadb -u "user" --password='pass' -e "SHOW GLOBAL STATUS LIKE 'wsrep_cluster_size';" --batch --skip-column-names | awk '/wsrep_cluster_size/ {print $2}')

# Vérifier si le nombre de nodes démarrés correspond à la taille du cluster
if [ "$CLUSTER_SIZE" == "$NODES" ]; then
    echo -e "${YELLOW}Le cluster Galera est complet avec $CLUSTER_SIZE nodes actifs.${NC}"
else
    echo -e "${YELLOW}Erreur : la taille du cluster Galera est $CLUSTER_SIZE, mais $NODES nodes sont démarrés.${NC}"
fi

# Attente de 30 secondes avant de finir le script
echo -e "${YELLOW}La restauration est terminée. Le script se terminera dans 15 secondes.${NC}"
sleep 15
