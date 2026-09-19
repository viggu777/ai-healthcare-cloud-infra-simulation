#!/usr/bin/env bash
# Create least-privilege MongoDB users on the LIVE db (for volumes that
# predate db/mongo-init.js per-service users, AND for fresh volumes whose
# init placeholders differ from the env-file passwords). SYNC semantics, not
# create-only: every run ends with each user's password == the env file value
# (createUser, falling back to changeUserPassword when the user exists).
# Uses root creds from the env file; api_user + worker_user get readWrite on
# `healthcare` only, monitor_user gets clusterMonitor on admin (no admin,
# no clusterAdmin, no app-data access).
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
function ensureUser(dbName, u, p, roles) {
  var d = db.getSiblingDB(dbName);
  try { d.createUser({user:u, pwd:p, roles:roles}); print(u+' created'); }
  catch(e){
    var m = String((e && e.message) || e);
    if (m.indexOf('already exists') !== -1) { d.changeUserPassword(u, p); print(u+' password synced'); }
    else { print(u+': '+m.split('\n')[0]); }
  }
}
ensureUser('healthcare', '$API_U', '$API_P', [{role:'readWrite', db:'healthcare'}]);
ensureUser('healthcare', '$WRK_U', '$WRK_P', [{role:'readWrite', db:'healthcare'}]);
ensureUser('admin', '$MON_U', '$MON_P', [{role:'clusterMonitor', db:'admin'}]);
print('users done (api_user, worker_user, monitor_user ensured)');
" 2>&1 | grep -v "^$"
echo "DB-USERS OK (verify: api/worker /ready still true after compose switch)"
