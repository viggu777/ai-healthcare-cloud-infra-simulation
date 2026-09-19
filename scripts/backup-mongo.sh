#!/usr/bin/env bash
# Phase 4 — MongoDB backup (as code, drilled — see docs/CICD.md backup section).
# Dumps the `healthcare` DB via an ephemeral mongo container attached to the
# Compose private network (same digest-pinned image as `db`, no new tooling).
# No host Mongo install needed; FOSS only.
#
# Usage:
#   bash scripts/backup-mongo.sh [--env-file environments/dev.env] [--out backups/<name>]
# Output: <out>/healthcare/{appointments,jobs}.bson (+ metadata). Prints document counts.
set -euo pipefail
cd "$(dirname "$0")/.."

export DOCKER_CONFIG="${DOCKER_CONFIG:-/tmp/docker-nocreds}"
ENV_FILE="environments/dev.env"
OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --env-file=*) ENV_FILE="${1#*=}"; shift ;;
    --env-file) ENV_FILE="$2"; shift 2 ;;
    --out=*) OUT="${1#*=}"; shift ;;
    --out) OUT="${2:?--out needs a value}"; shift 2 ;;
    environments/*) ENV_FILE="$1"; shift ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac
done

# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a
PROJECT="${COMPOSE_PROJECT_NAME:-ai-healthcare-sim}"
NET="${PROJECT}_private"
OUT="${OUT:-backups/backup-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"
# The mongo image runs as uid 999; open the fresh dir so the dump can be
# written through the bind mount (simulation-grade; files stay host-readable).
chmod 777 "$OUT"

echo "backing up healthcare DB (project $PROJECT, net $NET) -> $OUT"
docker run --rm --network "$NET" -v "$(pwd)/$OUT:/dump" \
  mongo:7-jammy@sha256:84c4a18b60a0e73d1577112b0a600b46cab477c64cfe0ff36d0647bbca055bd0 \
  mongodump --uri="mongodb://${MONGO_USER:-app}:${MONGO_PASSWORD:-app_secret_change_me}@db:27017/healthcare?authSource=admin" \
  --out=/dump
# The dump files belong to the image uid (999); loosen them so the host admin
# owns their lifecycle (retention cleanup) without needing root on the host.
docker run --rm --user root -v "$(pwd)/$OUT:/dump" --entrypoint chmod \
  mongo:7-jammy@sha256:84c4a18b60a0e73d1577112b0a600b46cab477c64cfe0ff36d0647bbca055bd0 \
  -R a+rw /dump
echo "--- backup contents ---"
find "$OUT" -type f | sort
echo "--- document counts (live DB) ---"
docker compose --env-file "$ENV_FILE" exec db mongosh --quiet \
  -u "${MONGO_USER:-app}" -p "${MONGO_PASSWORD:-app_secret_change_me}" \
  --eval "db.getSiblingDB('healthcare').appointments.countDocuments({})" 2>/dev/null
echo "BACKUP OK: $OUT"
