#!/bin/bash

# Couleur pour les messages (jaune)
YELLOW='\033[1;33m'
NC='\033[0m' # Pas de couleur

# Informations de connexion MariaDB codées en dur
DB_USER="root"
DB_PASSWORD="pass"

# Liste des nodes arrêtés à redémarrer plus tard
STOPPED_NODES=()

# Fonction pour arrêter les nodes Docker (sauf mariadb-node1)
echo -e "${YELLOW}Arrêt des nodes Docker mariadb-nodeX sauf mariadb-node1...${NC}"
for NODE in $(docker ps --format "{{.Names}}" | grep "mariadb-node" | grep -v "mariadb-node1"); do
    docker stop "$NODE"
    if [ $? -eq 0 ]; then
        echo -e "${YELLOW}Node $NODE arrêté avec succès.${NC}"
        STOPPED_NODES+=("$NODE") # Ajouter à la liste des nodes arrêtés
    else
        echo -e "${YELLOW}Erreur lors de l'arrêt de $NODE.${NC}"
    fi
done

# Pause de 30 secondes avant de lancer la sauvegarde
echo -e "${YELLOW}Attente de 30 secondes avant de lancer la sauvegarde...${NC}"
sleep 30

# Exécution de la commande de sauvegarde sur mariadb-node1 (silencieuse)
echo -e "${YELLOW}Exécution de la commande de sauvegarde sur mariadb-node1...${NC}"
docker exec -u root mariadb-node1 mariadb-backup --backup --target-dir /bitnami/mariadb/backup/ --user "$DB_USER" --password "$DB_PASSWORD" > /dev/null 2>&1

if [ $? -eq 0 ]; then
    echo -e "${YELLOW}La sauvegarde sur mariadb-node1 a été effectuée avec succès.${NC}"
else
    echo -e "${YELLOW}Erreur lors de la sauvegarde sur mariadb-node1.${NC}"
    exit 1
fi

# Définir le dossier source
SOURCE_DIR="/backup/mariadb"

# Définir le dossier de destination
DEST_DIR="/backup"

# Générer la date et l'heure actuelles
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# Nom de l'archive
ARCHIVE_NAME="backup_$TIMESTAMP.tar.gz"

# Créer l'archive (silencieux)
tar -czf "$DEST_DIR/$ARCHIVE_NAME" -C "$SOURCE_DIR" . > /dev/null 2>&1

# Vérifier si la commande tar a réussi
if [ $? -eq 0 ]; then
    echo -e "${YELLOW}L'archive $ARCHIVE_NAME a été créée avec succès dans $DEST_DIR.${NC}"
else
    echo -e "${YELLOW}Erreur lors de la création de l'archive.${NC}"
    exit 1
fi

# Supprimer les anciennes archives si plus de 4 sont présentes
cd "$DEST_DIR"
ARCHIVES_COUNT=$(ls backup_*.tar.gz 2>/dev/null | wc -l)

if [ "$ARCHIVES_COUNT" -gt 4 ]; then
    echo -e "${YELLOW}Plus de 4 sauvegardes présentes, suppression des plus anciennes.${NC}"
    ls -t backup_*.tar.gz | tail -n +5 | xargs rm -f
fi

# Purger le contenu du dossier mariadb après la sauvegarde
echo -e "${YELLOW}Purge du contenu du dossier $SOURCE_DIR.${NC}"
rm -rf "$SOURCE_DIR"/*

# Vérifier si la purge a réussi
if [ $? -eq 0 ]; then
    echo -e "${YELLOW}Le dossier $SOURCE_DIR a été purgé avec succès.${NC}"
else
    echo -e "${YELLOW}Erreur lors de la purge du dossier $SOURCE_DIR.${NC}"
    exit 1
fi

# Redémarrer les nodes Docker qui ont été arrêtés, avec un délai de 1 minute entre chaque
echo -e "${YELLOW}Redémarrage des nodes Docker arrêtés avec un délai de 1 minute entre chaque...${NC}"

for NODE in "${STOPPED_NODES[@]}"; do
    docker start "$NODE"
    if [ $? -eq 0 ]; then
        echo -e "${YELLOW}Node $NODE redémarré avec succès.${NC}"
    else
        echo -e "${YELLOW}Erreur lors du redémarrage de $NODE.${NC}"
    fi
    echo -e "${YELLOW}Attente de 1 minute avant de redémarrer le prochain node...${NC}"
    sleep 60
done

# Vérifier que tous les nodes mariadb sont démarrés
echo -e "${YELLOW}Vérification du démarrage de tous les nodes mariadb...${NC}"
ALL_NODES=$(docker ps --format "{{.Names}}" | grep "mariadb-node" | wc -l)
echo -e "${YELLOW}$ALL_NODES nodes mariadb sont actuellement démarrés.${NC}"

# Exécuter la commande SQL pour vérifier la taille du cluster Galera
echo -e "${YELLOW}Exécution de la commande SHOW GLOBAL STATUS LIKE 'wsrep_cluster_size'; sur mariadb-node1...${NC}"

# Récupérer uniquement la valeur de wsrep_cluster_size sans en-tête
CLUSTER_SIZE=$(docker exec -u root mariadb-node1 mariadb -u "root" --password='pass' -e "SHOW GLOBAL STATUS LIKE 'wsrep_cluster_size';" --batch --skip-column-names | awk '/wsrep_cluster_size/ {print $2}')

# Vérifier si le nombre de nodes démarrés correspond à la taille du cluster
if [ "$CLUSTER_SIZE" == "$ALL_NODES" ]; then
    echo -e "${YELLOW}Le cluster Galera est complet avec $CLUSTER_SIZE nodes actifs.${NC}"
else
    echo -e "${YELLOW}Erreur : la taille du cluster Galera est $CLUSTER_SIZE, mais $ALL_NODES nodes sont démarrés.${NC}"
fi

# Attendre 30 secondes avant la fin du script
echo -e "${YELLOW}Le script se terminera dans 30 secondes.${NC}"
sleep 30
