#!/usr/bin/env bash
# Create least-privilege MongoDB users on the LIVE db (for volumes that
# predate db/mongo-init.js per-service users). Idempotent: safe to re-run.
# Uses root creds from the env file; creates api_user + worker_user with
# readWrite on `healthcare` only (no admin, no clusterAdmin).
# Usage: bash scripts/create-db-users.sh [--env-file environments/dev.env]
set -euo pipefail
cd "$(dirname "$0")/.."
export DOCKER_CONFIG="${DOCKER_CONFIG:-/tmp/docker-nocreds}"
ENV_FILE="environments/dev.env"
for a in "$@"; do case "$a" in --env-file=*) ENV_FILE="${a#*=}";; --env-file) ENV_FILE="$2"; shift;; environments/*) ENV_FILE="$a";; esac; done
# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a
API_U="${MONGO_API_USER:-api_user}"; API_P="${MONGO_API_PASSWORD:-api_only_change_me}"
WRK_U="${MONGO_WORKER_USER:-worker_user}"; WRK_P="${MONGO_WORKER_PASSWORD:-worker_only_change_me}"
MON_U="${MONGO_MONITOR_USER:-monitor_user}"; MON_P="${MONGO_MONITOR_PASSWORD:-monitor_only_change_me}"
echo "creating least-privilege users on $COMPOSE_PROJECT_NAME (root: ${MONGO_USER:-app})"
docker compose --env-file "$ENV_FILE" exec -T db mongosh --quiet \
  -u "${MONGO_USER:-app}" -p "${MONGO_PASSWORD:-app_secret_change_me}" --authenticationDatabase admin \
  --eval "
try { db.getSiblingDB('healthcare').createUser({user:'$API_U',pwd:'$API_P',roles:[{role:'readWrite',db:'healthcare'}]}); print('api_user created'); }
catch(e){ print('api_user: '+e.message.split('\n')[0]); }
try { db.getSiblingDB('healthcare').createUser({user:'$WRK_U',pwd:'$WRK_P',roles:[{role:'readWrite',db:'healthcare'}]}); print('worker_user created'); }
catch(e){ print('worker_user: '+e.message.split('\n')[0]); }
try { db.getSiblingDB('admin').createUser({user:'$MON_U',pwd:'$MON_P',roles:[{role:'clusterMonitor',db:'admin'}]}); print('monitor_user created'); }
catch(e){ print('monitor_user: '+e.message.split('\n')[0]); }
print('users done (api_user, worker_user, monitor_user ensured)');
" 2>&1 | grep -v "^$"
echo "DB-USERS OK (verify: api/worker /ready still true after compose switch)"
