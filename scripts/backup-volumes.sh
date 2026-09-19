#!/usr/bin/env bash
# Full-state backup: Mongo dump + all named volumes + checksums (PRD §19).
# Mongo holds app state; queue-data (AOF), prometheus-data, grafana-data hold
# buffer/monitoring state an operator needs after host loss. Each artifact gets
# a SHA256SUMS so restores are integrity-verified, not assumed.
# Usage: bash scripts/backup-volumes.sh [--env-file environments/dev.env] [--out backups/state-<ts>] [--keep N]
set -euo pipefail
cd "$(dirname "$0")/.."
export DOCKER_CONFIG="${DOCKER_CONFIG:-/tmp/docker-nocreds}"
ENV_FILE="environments/dev.env"; OUT=""; KEEP=7
while [ $# -gt 0 ]; do case "$1" in --env-file=*) ENV_FILE="${1#*=}"; shift;; --env-file) ENV_FILE="$2"; shift 2;; --out=*) OUT="${1#*=}"; shift;; --out) OUT="$2"; shift 2;; --keep=*) KEEP="${1#*=}"; shift;; --keep) KEEP="$2"; shift 2;; *) shift;; esac; done
# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a
PROJECT="${COMPOSE_PROJECT_NAME:-ai-healthcare-sim}"
OUT="${OUT:-backups/state-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"; chmod 777 "$OUT"
echo "state backup ($PROJECT) -> $OUT"
bash scripts/backup-mongo.sh --env-file "$ENV_FILE" --out "$OUT/mongo" 2>&1 | tail -2
for vol in queue-data prometheus-data grafana-data; do
  src="${PROJECT}_${vol}"
  if docker volume inspect "$src" >/dev/null 2>&1; then
    docker run --rm -v "$src:/src:ro" -v "$(pwd)/$OUT:/dst" alpine:3.20 \
      tar -czf "/dst/${vol}.tar.gz" -C /src . 2>&1 | tail -1 || echo "  ($vol: tar via alpine failed — volume present but empty?)"
    echo "  [ok] $vol -> $OUT/${vol}.tar.gz"
  else
    echo "  [skip] volume $src not present"
  fi
done
docker run --rm --user root -v "$(pwd)/$OUT:/d" --entrypoint chmod \
  mongo:7-jammy@sha256:84c4a18b60a0e73d1577112b0a600b46cab477c64cfe0ff36d0647bbca055bd0 \
  -R a+r /d 2>/dev/null || true
(cd "$OUT" && sha256sum $(find . -type f ! -name SHA256SUMS | sort) >SHA256SUMS)
cat "$OUT/SHA256SUMS"
# Retention: keep the newest $KEEP state-* dirs (same --keep semantics as
# backup-mongo.sh) so a future cron promotion cannot fill the disk.
if [ "$KEEP" -gt 0 ]; then
  ls -dt backups/state-* 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -rf
  echo "  retention: newest $KEEP state-* kept ($(ls -d backups/state-* 2>/dev/null | wc -l) present)"
fi
echo "STATE-BACKUP OK: $OUT (verify: sha256sum -c $OUT/SHA256SUMS)"
