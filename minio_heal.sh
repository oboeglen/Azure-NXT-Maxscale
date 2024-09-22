#!/bin/bash

# Nom du conteneur Docker Minio
CONTAINER="storage-node1"

# Informations d'authentification Minio
ACCESS_KEY="myaccesskey"
SECRET_KEY="mysecretkey"
MINIO_ALIAS="local"
MINIO_ENDPOINT="http://localhost:9000"
BUCKET_NAME="mybucket"

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
echo -e "\e[32mGuérison en cours...\e[0m"
attempt_heal

# Vérifier si la guérison a échoué
if [ $? -ne 0 ]; then
  echo "Erreur lors de la guérison. Nouvelle tentative dans 30 secondes..."
  sleep 30
  
  # Retenter la guérison
  attempt_heal
  
  if [ $? -ne 0 ]; then
    echo "Échec de la guérison après la seconde tentative."
    exit 1
  else
    echo "Guérison réussie lors de la seconde tentative."
  fi
else
  echo "Guérison réussie lors de la première tentative."
fi

# Fin du script
echo "Resynchronisation de Minio terminée."