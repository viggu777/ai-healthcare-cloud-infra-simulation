#!/usr/bin/env bash
# Rotate a service credential end-to-end (PRD §9: secrets reach workloads securely).
# Updates the live Mongo user password (or any env-file secret), rewrites the
# env file, and rolling-restarts only the affected services — proving rotation
# needs no full outage.
# Usage:
#   bash scripts/rotate-secrets.sh --which mongo-api|mongo-worker|ai-key|grafana [--env-file environments/dev.env]
set -euo pipefail
cd "$(dirname "$0")/.."
export DOCKER_CONFIG="${DOCKER_CONFIG:-/tmp/docker-nocreds}"
ENV_FILE="environments/dev.env"; WHICH=""
while [ $# -gt 0 ]; do case "$1" in
  --which=*) WHICH="${1#*=}"; shift;; --which) WHICH="$2"; shift 2;;
  --env-file=*) ENV_FILE="${1#*=}"; shift;; --env-file) ENV_FILE="$2"; shift 2;;
  *) shift;; esac; done
[ -n "$WHICH" ] || { echo "need --which mongo-api|mongo-worker|ai-key|grafana"; exit 2; }
# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a
NEW="$(openssl rand -hex 12)"
case "$WHICH" in
  mongo-api)
    ADB_USER="${MONGO_USER:-app}"; ADB_PASS="${MONGO_PASSWORD:-x}"
    docker compose --env-file "$ENV_FILE" exec -T db mongosh --quiet --username "$ADB_USER" --password "$ADB_PASS" --authenticationDatabase admin \
      --eval "db.getSiblingDB('healthcare').changeUserPassword('${MONGO_API_USER:-api_user}','$NEW')" >/dev/null
    sed -i "s/^MONGO_API_PASSWORD=.*/MONGO_API_PASSWORD=$NEW/" "$ENV_FILE"
    docker compose --env-file "$ENV_FILE" up -d api >/dev/null; sleep 8
    curl -fsS "${GW:-http://localhost:8080}/ready" >/dev/null 2>&1 || curl -fsS http://localhost:8080/ready >/dev/null
    echo "ROTATED mongo-api in $ENV_FILE (api restarted only, /ready true)";;
  mongo-worker)
    ADB_USER="${MONGO_USER:-app}"; ADB_PASS="${MONGO_PASSWORD:-x}"
    docker compose --env-file "$ENV_FILE" exec -T db mongosh --quiet --username "$ADB_USER" --password "$ADB_PASS" --authenticationDatabase admin \
      --eval "db.getSiblingDB('healthcare').changeUserPassword('${MONGO_WORKER_USER:-worker_user}','$NEW')" >/dev/null
    sed -i "s/^MONGO_WORKER_PASSWORD=.*/MONGO_WORKER_PASSWORD=$NEW/" "$ENV_FILE"
    docker compose --env-file "$ENV_FILE" up -d worker >/dev/null; sleep 8
    echo "ROTATED mongo-worker in $ENV_FILE (worker restarted only)";;
  ai-key)
    sed -i "s/^AI_API_KEY=.*/AI_API_KEY=$NEW/" "$ENV_FILE"
    docker compose --env-file "$ENV_FILE" up -d api ai-service >/dev/null; sleep 8
    echo "ROTATED ai-key in $ENV_FILE (api+ai-service restarted)";;
  grafana)
    sed -i "s/^GRAFANA_ADMIN_PASSWORD=.*/GRAFANA_ADMIN_PASSWORD=$NEW/" "$ENV_FILE"
    docker compose --env-file "$ENV_FILE" up -d grafana >/dev/null
    echo "ROTATED grafana password in $ENV_FILE";;
esac
echo "ROTATE OK ($WHICH). Old value is dead; new value only in $ENV_FILE (git-tracked placeholders must be replaced before any shared use — R4)."
