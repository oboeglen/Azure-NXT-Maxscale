#!/bin/bash

# Nom du conteneur Docker Minio
CONTAINER="storage-node1"

# Informations d'authentification Minio
ACCESS_KEY="myaccesskey"
SECRET_KEY="mysecretkey"
MINIO_ALIAS="local"
MINIO_ENDPOINT="http://localhost:9000"
BUCKET_NAME="mybucket"
BASE_DATA_PATH="/data"  # Base path des données, à adapter si nécessaire

# Fonction pour tenter la guérison et réessayer en cas d'échec
attempt_heal() {
  docker exec $CONTAINER sh -c "
    # Lancer la commande heal avec analyse profonde, masquant la sortie
    mc admin heal --scan deep -r $MINIO_ALIAS/$BUCKET_NAME > /dev/null 2>&1
  "
}

# Exécuter les commandes dans le conteneur Docker sans interaction
docker exec $CONTAINER sh -c "
  # Vérifier l'état du cluster Minio
  mc admin info $MINIO_ALIAS
"

# Pause de 30 secondes
sleep 30

# Configurer l'alias avec les clés d'accès
docker exec $CONTAINER sh -c "
  mc alias set $MINIO_ALIAS $MINIO_ENDPOINT $ACCESS_KEY $SECRET_KEY
"

# Tenter la guérison
echo -e "\e[33mGuérison en cours...\e[0m"
attempt_heal

# Vérifier si la guérison a échoué
if [ $? -ne 0 ]; then
  echo -e "\e[31mErreur lors de la guérison.\e[0m Nouvelle tentative dans 30 secondes..."
  sleep 30
  
  # Retenter la guérison
  attempt_heal
  
  if [ $? -ne 0 ]; then
    echo -e "\e[31mÉchec de la guérison après la seconde tentative.\e[0m"
    exit 1
  else
    echo -e "\e[32mGuérison réussie lors de la seconde tentative.\e[0m"
  fi
else
  echo -e "\e[32mGuérison réussie lors de la première tentative.\e[0m"
fi

# Vérification des dossiers /data* et affichage de l'espace utilisé
echo -e "\e[33mVérification des dossiers /data...\e[0m"

for i in {1..10}; do  # Vérifie jusqu'à 10 dossiers /data (peut être ajusté)
  DATA_PATH="${BASE_DATA_PATH}${i}"
  
  if [ -d "$DATA_PATH" ]; then
    echo -e "\e[34mEspace utilisé pour $DATA_PATH :\e[0m"
    df -h --output=source,size,used,avail,pcent "$DATA_PATH" | awk 'NR==1{print; next} {print "\033[33m" $0 "\033[0m"}'
  else
    echo "$DATA_PATH n'existe pas."
    break  # Sortir de la boucle si le dossier suivant n'existe pas
  fi
done

# Pause de 30 secondes pour laisser le temps de vérifier les résultats
echo -e "\e[32mPause de 30 secondes pour examiner l'espace disque...\e[0m"
sleep 30

# Fin du script
echo "Resynchronisation de Minio terminée."