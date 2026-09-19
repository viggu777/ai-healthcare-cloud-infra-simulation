#!/usr/bin/env bash
# Phase 4 — MongoDB backup (as code, drilled — see docs/CICD.md backup section).
# Dumps the `healthcare` DB via an ephemeral mongo container attached to the
# Compose private network (same digest-pinned image as `db`, no new tooling).
# No host Mongo install needed; FOSS only.
#
# RETENTION POLICY (P0.3): after every successful backup, only the newest
# $KEEP backups matching `backups/backup-*` are kept; older ones are deleted.
# Default KEEP=5 (override: `--keep N` or `KEEP_BACKUPS=N`). Directories NOT
# matching `backup-*` (e.g. `drill-p4` evidence, `.gitkeep`) are never pruned.
# Deletion runs through a uid-0 ephemeral container because dump files belong
# to the image uid (999) and are host-undeletable otherwise (P0.3 residue fix).
#
# Usage:
#   bash scripts/backup-mongo.sh [--env-file environments/dev.env] [--out backups/<name>] [--keep N]
# Output: <out>/healthcare/{appointments,jobs}.bson (+ metadata). Prints document counts.
set -euo pipefail
cd "$(dirname "$0")/.."

export DOCKER_CONFIG="${DOCKER_CONFIG:-/tmp/docker-nocreds}"
ENV_FILE="environments/dev.env"
OUT=""
KEEP="${KEEP_BACKUPS:-5}"
while [ $# -gt 0 ]; do
  case "$1" in
    --env-file=*) ENV_FILE="${1#*=}"; shift ;;
    --env-file) ENV_FILE="$2"; shift 2 ;;
    --out=*) OUT="${1#*=}"; shift ;;
    --out) OUT="${2:?--out needs a value}"; shift 2 ;;
    --keep=*) KEEP="${1#*=}"; shift ;;
    --keep) KEEP="${2:?--keep needs a value}"; shift 2 ;;
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
# ---- retention: keep newest $KEEP backups/backup-*/ dirs, prune the rest ----
echo "--- retention (keep newest $KEEP in backups/backup-*) ---"
mapfile -t ALL_BK < <(ls -dt backups/backup-*/ 2>/dev/null || true)
echo "  found ${#ALL_BK[@]} backup(s)"
if [ "${#ALL_BK[@]}" -gt "$KEEP" ]; then
  for old in "${ALL_BK[@]:$KEEP}"; do
    echo "  pruning $old"
    if rm -rf "$old" 2>/dev/null; then
      echo "  pruned via host rm: $old"
    else
      # uid-999-owned residue: delete through a uid-0 ephemeral container.
      docker run --rm --user root -v "$(pwd)/backups:/b" --entrypoint sh \
        mongo:7-jammy@sha256:84c4a18b60a0e73d1577112b0a600b46cab477c64cfe0ff36d0647bbca055bd0 \
        -c "rm -rf '/b/$(basename "$old")' && echo '  pruned via uid-0 container: $old'"
    fi
  done
else
  echo "  within retention (nothing to prune)"
fi
