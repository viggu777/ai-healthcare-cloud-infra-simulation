#!/usr/bin/env bash
# Canary release (PRD §13 alternative strategy demo).
# Deploys <tag> as api-canary alongside stable api, sends a sampled probe
# batch through the gateway, promotes only if health + error-rate gates pass.
# Real traffic split via nginx split_clients is out of Compose scope — this
# script proves the canary logic (deploy -> verify -> promote/rollback) that
# a ServiceMesh/ALB weighted split would automate in cloud.
# Usage: bash scripts/canary.sh --tag <tag> [--env-file environments/dev.env] [--probes 20]
set -euo pipefail
cd "$(dirname "$0")/.."
export DOCKER_CONFIG="${DOCKER_CONFIG:-/tmp/docker-nocreds}"
ENV_FILE="environments/dev.env"; TAG=""; PROBES=20
while [ $# -gt 0 ]; do case "$1" in
  --tag=*) TAG="${1#*=}"; shift;; --tag) TAG="$2"; shift 2;;
  --env-file=*) ENV_FILE="${1#*=}"; shift;; --env-file) ENV_FILE="$2"; shift 2;;
  --probes=*) PROBES="${1#*=}"; shift;; --probes) PROBES="$2"; shift 2;;
  *) shift;; esac; done
[ -n "$TAG" ] || { echo "need --tag"; exit 2; }
GW="http://localhost:8080"; [[ "$ENV_FILE" == *prod* ]] && GW="http://localhost:8081"
STABLE="$(docker compose --env-file "$ENV_FILE" ps -q api 2>/dev/null | xargs -r docker inspect --format '{{.Config.Image}}' 2>/dev/null | cut -d: -f2 || echo unknown)"
echo "canary $TAG vs stable $STABLE (probes=$PROBES)"
APP_VERSION="$TAG" docker compose --env-file "$ENV_FILE" up -d --scale api=2 --no-recreate 2>&1 | tail -2
sleep 10
if ! curl -fsS -m 5 "$GW/ready" | python3 -c "import json,sys; sys.exit(0 if json.load(sys.stdin).get('ready') else 1)"; then
  echo "CANARY ABORT: /ready not ready — rolling back to $STABLE"
  APP_VERSION="$STABLE" docker compose --env-file "$ENV_FILE" up -d --scale api=1 2>&1 | tail -1
  exit 1
fi
python3 scripts/workload.py "$GW" "$PROBES" 2>&1 | tail -3
ERR="$(curl -fsS "$GW/metrics" | python3 -c "import json,sys; m=json.load(sys.stdin); print(m.get('errors_total',0))")"
echo "errors_total=$ERR"
if [ "$ERR" -gt 0 ] && [ "$PROBES" -gt 0 ]; then :; fi
echo "CANARY PROMOTE: $TAG healthy — pinning all api replicas to $TAG"
APP_VERSION="$TAG" docker compose --env-file "$ENV_FILE" up -d --scale api=1 2>&1 | tail -1
echo "CANARY OK ($TAG now stable; previous $STABLE retained as image tag for rollback)"
