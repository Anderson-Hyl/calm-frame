#!/usr/bin/env bash
# db-up.sh — start the local development Postgres container.
#
# Uses Apple's `container` CLI (macOS 26 / Apple silicon).
# If `container` is not installed:
#   brew install container
#   container system start
#
# The database matches the DATABASE_URL default in Server/.env.example:
#   postgres://calmframe:calmframe@localhost:5432/calmframe

set -euo pipefail

CONTAINER_NAME="calmframe-postgres"
POSTGRES_IMAGE="docker.io/library/postgres:16-alpine"
POSTGRES_USER="calmframe"
POSTGRES_PASSWORD="calmframe"
POSTGRES_DB="calmframe"
HOST_PORT="5432"

# Ensure the container system service is running.
if ! container system status &>/dev/null; then
  echo "Starting container system service..."
  container system start
fi

# If the container already exists and is running, do nothing.
if container list --all 2>/dev/null | grep -q "^${CONTAINER_NAME}"; then
  echo "Container '${CONTAINER_NAME}' already exists."
  if container list 2>/dev/null | grep -q "^${CONTAINER_NAME}"; then
    echo "Already running — nothing to do."
  else
    echo "Starting stopped container..."
    container start "${CONTAINER_NAME}"
    echo "Postgres is up on localhost:${HOST_PORT}"
  fi
  exit 0
fi

echo "Pulling image ${POSTGRES_IMAGE} (if needed)..."
container image pull "${POSTGRES_IMAGE}"

echo "Starting Postgres container '${CONTAINER_NAME}'..."
container run \
  --detach \
  --name "${CONTAINER_NAME}" \
  --publish "127.0.0.1:${HOST_PORT}:5432" \
  --env "POSTGRES_USER=${POSTGRES_USER}" \
  --env "POSTGRES_PASSWORD=${POSTGRES_PASSWORD}" \
  --env "POSTGRES_DB=${POSTGRES_DB}" \
  "${POSTGRES_IMAGE}"

echo ""
echo "Postgres is up on localhost:${HOST_PORT}"
echo "  DATABASE_URL=postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@localhost:${HOST_PORT}/${POSTGRES_DB}"
