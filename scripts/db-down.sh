#!/usr/bin/env bash
# db-down.sh — stop (and optionally remove) the local development Postgres container.
#
# Usage:
#   ./scripts/db-down.sh          # stop the container, keep data volume
#   ./scripts/db-down.sh --rm     # stop AND remove the container (data is lost)

set -euo pipefail

CONTAINER_NAME="calmframe-postgres"
REMOVE=false

for arg in "$@"; do
  case "$arg" in
    --rm) REMOVE=true ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

if ! container list --all 2>/dev/null | grep -q "^${CONTAINER_NAME}"; then
  echo "Container '${CONTAINER_NAME}' does not exist — nothing to do."
  exit 0
fi

echo "Stopping container '${CONTAINER_NAME}'..."
container stop "${CONTAINER_NAME}"

if [ "$REMOVE" = true ]; then
  echo "Removing container '${CONTAINER_NAME}'..."
  container delete "${CONTAINER_NAME}"
  echo "Container removed. Database data has been discarded."
else
  echo "Container stopped. Data is preserved."
  echo "Run './scripts/db-up.sh' to start it again, or './scripts/db-down.sh --rm' to remove it."
fi
