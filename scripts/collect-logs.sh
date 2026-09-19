#!/usr/bin/env bash
# Log bundle collector (centralized-logging stand-in, PRD §16).
# Loki is future P2; this script is the auditable interim: one timestamped
# tarball with every service's logs + compose ps + alert snapshot.
# Usage: bash scripts/collect-logs.sh [--env-file environments/dev.env] [--out logs/bundle-<ts>.tar.gz]
set -euo pipefail
cd "$(dirname "$0")/.."
export DOCKER_CONFIG="${DOCKER_CONFIG:-/tmp/docker-nocreds}"
ENV_FILE="environments/dev.env"; OUT=""
while [ $# -gt 0 ]; do case "$1" in --env-file=*) ENV_FILE="${1#*=}"; shift;; --env-file) ENV_FILE="$2"; shift 2;; --out=*) OUT="${1#*=}"; shift;; --out) OUT="$2"; shift 2;; *) shift;; esac; done
OUT="${OUT:-logs/bundle-$(date +%Y%m%d-%H%M%S).tar.gz}"
mkdir -p "$(dirname "$OUT")" /tmp/logbundle-$$
trap 'rm -rf /tmp/logbundle-$$' EXIT
docker compose --env-file "$ENV_FILE" ps --format 'table {{.Service}}\t{{.Status}}' >"/tmp/logbundle-$$/ps.txt" 2>&1 || true
for svc in gateway api ai-service worker queue db ehr-mock prometheus alertmanager pushgateway grafana redis-exporter mongodb-exporter nginx-exporter alert-logger; do
  docker compose --env-file "$ENV_FILE" logs --no-log-prefix --tail=500 "$svc" >"/tmp/logbundle-$$/$svc.log" 2>&1 || echo "(no logs: $svc)" >"/tmp/logbundle-$$/$svc.log"
done
docker compose --env-file "$ENV_FILE" exec -T prometheus wget -qO- 'http://localhost:9090/api/v1/alerts' >"/tmp/logbundle-$$/alerts.json" 2>/dev/null || echo '{}' >"/tmp/logbundle-$$/alerts.json"
tar -czf "$OUT" -C /tmp/logbundle-$$ .
sha256sum "$OUT"
echo "LOG-BUNDLE OK: $OUT ($(tar -tzf "$OUT" | wc -l) files)"
