#!/usr/bin/env bash
# Phase 4 — MongoDB restore (as code, drilled — see docs/CICD.md backup section).
# Restores a `scripts/backup-mongo.sh` dump WITHOUT --drop (upsert by _id):
# deleted documents come back, everything written since the backup is untouched.
# For full-disaster rebuild (wiped volume), add --drop — documented in the drill.
#
# Usage:
#   bash scripts/restore-mongo.sh [--env-file environments/dev.env] <backup-dir>
set -euo pipefail
cd "$(dirname "$0")/.."

export DOCKER_CONFIG="${DOCKER_CONFIG:-/tmp/docker-nocreds}"
ENV_FILE="environments/dev.env"
BACKUP=""
for arg in "$@"; do
  case "$arg" in
    --env-file=*) ENV_FILE="${arg#*=}" ;;
    environments/*) ENV_FILE="$arg" ;;
    *) BACKUP="$arg" ;;
  esac
done
if [ -z "$BACKUP" ] || [ ! -d "$BACKUP" ]; then
  echo "usage: bash scripts/restore-mongo.sh [--env-file $ENV_FILE] <backup-dir>"; exit 2
fi

# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a
PROJECT="${COMPOSE_PROJECT_NAME:-ai-healthcare-sim}"
NET="${PROJECT}_private"

echo "restoring healthcare DB (project $PROJECT) from $BACKUP (no --drop: upsert by _id)"
docker run --rm --network "$NET" -v "$(pwd)/$BACKUP:/dump:ro" \
  mongo:7-jammy@sha256:84c4a18b60a0e73d1577112b0a600b46cab477c64cfe0ff36d0647bbca055bd0 \
  mongorestore --uri="mongodb://${MONGO_USER:-app}:${MONGO_PASSWORD:-app_secret_change_me}@db:27017/healthcare?authSource=admin" \
  /dump/healthcare
echo "--- document counts (live DB) ---"
docker compose --env-file "$ENV_FILE" exec db mongosh --quiet \
  -u "${MONGO_USER:-app}" -p "${MONGO_PASSWORD:-app_secret_change_me}" \
  --eval "db.getSiblingDB('healthcare').appointments.countDocuments({})" 2>/dev/null
echo "RESTORE OK from $BACKUP"
