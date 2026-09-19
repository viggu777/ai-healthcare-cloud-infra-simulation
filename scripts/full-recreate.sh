#!/usr/bin/env bash
# Full-disaster recreate drill (PRD §19: infra recreation vs state recovery).
# DANGER: wipes ALL volumes for the given env (down -v). Requires explicit
# `--i-understand-this-wipes-volumes` plus a verified backup dir.
# Steps: down -v -> up -d -> wait /ready -> restore --drop -> smoke.
# Usage:
#   bash scripts/full-recreate.sh --env-file environments/dev.env \
#     --backup backups/backup-YYYYMMDD-HHMMSS --i-understand-this-wipes-volumes
set -euo pipefail
cd "$(dirname "$0")/.."
export DOCKER_CONFIG="${DOCKER_CONFIG:-/tmp/docker-nocreds}"
ENV_FILE="environments/dev.env"; BACKUP=""; CONFIRM=0
while [ $# -gt 0 ]; do case "$1" in
  --env-file=*) ENV_FILE="${1#*=}"; shift;; --env-file) ENV_FILE="$2"; shift 2;;
  --backup=*) BACKUP="${1#*=}"; shift;; --backup) BACKUP="$2"; shift 2;;
  --i-understand-this-wipes-volumes) CONFIRM=1; shift;;
  *) echo "unknown arg $1"; exit 2;; esac; done
[ "$CONFIRM" -eq 1 ] || { echo "refusing: pass --i-understand-this-wipes-volumes"; exit 2; }
[ -d "${BACKUP:-}" ] || { echo "need --backup <existing dir>"; exit 2; }
GW="http://localhost:8080"; [[ "$ENV_FILE" == *prod* ]] && GW="http://localhost:8081"
echo "STEP 1/5 wiping volumes ($ENV_FILE)…"
docker compose --env-file "$ENV_FILE" down -v
echo "STEP 2/5 recreating from IaC…"
docker compose --env-file "$ENV_FILE" up -d --build
echo "STEP 3/5 waiting /ready (120s)…"
for i in $(seq 1 24); do curl -fsS "$GW/ready" 2>/dev/null | python3 -c "import json,sys; sys.exit(0 if json.load(sys.stdin).get('ready') else 1)" && break; sleep 5; done
echo "STEP 4/5 restoring $BACKUP with --drop (full-disaster variant)…"
NET="$(grep -E '^COMPOSE_PROJECT_NAME=' "$ENV_FILE" | cut -d= -f2)_private"
# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a
docker run --rm --network "$NET" -v "$(pwd)/$BACKUP:/dump:ro" \
  mongo:7-jammy@sha256:84c4a18b60a0e73d1577112b0a600b46cab477c64cfe0ff36d0647bbca055bd0 \
  mongorestore --uri="mongodb://${MONGO_USER:-app}:${MONGO_PASSWORD:-x}@db:27017/healthcare?authSource=admin" --drop /dump/healthcare
bash scripts/create-db-users.sh --env-file "$ENV_FILE"
docker compose --env-file "$ENV_FILE" up -d api worker
sleep 8
echo "STEP 5/5 verifying…"
GATEWAY_URL="$GW" bash scripts/smoke.sh
echo "FULL-RECREATE OK (infra from IaC, state from backup, users re-created)"
