#!/usr/bin/env bash
# P1.5 — Install the MongoDB backup cron schedule (as code, idempotent).
# Honest RPO for the simulation: backups run unattended on a schedule instead
# of "whenever someone remembers". Retention (keep N latest) lives in
# scripts/backup-mongo.sh itself, so every scheduled run also prunes.
#
# Usage:
#   bash scripts/install-backup-cron.sh [--every-minutes N]   # verification cadence
#   bash scripts/install-backup-cron.sh [--daily HH:MM]       # production cadence (default 03:17)
#   bash scripts/install-backup-cron.sh --remove              # uninstall
# The installer rewrites only its own cron line (matched by marker); any other
# crontab entries are left untouched. Run output goes to backups/backup-cron.log.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"

SCHEDULE="17 3 * * *"
REMOVE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --every-minutes=*) SCHEDULE="*/${1#*=} * * * *"; shift ;;
    --every-minutes) SCHEDULE="*/$2 * * * *"; shift 2 ;;
    --daily=*) HM="${1#*=}"; SCHEDULE="$(echo "$HM" | cut -d: -f2) $(echo "$HM" | cut -d: -f1) * * *"; shift ;;
    --daily) HM="$2"; SCHEDULE="$(echo "$HM" | cut -d: -f2) $(echo "$HM" | cut -d: -f1) * * *"; shift 2 ;;
    --remove) REMOVE=1; shift ;;
    -h|--help) sed -n '2,/^# Usage/p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1 (see --help)"; exit 2 ;;
  esac
done

MARKER="# ai-healthcare-sim backup-mongo (managed by scripts/install-backup-cron.sh)"
LINE="$SCHEDULE PATH=/usr/local/bin:/usr/bin:/bin /bin/bash $REPO/scripts/backup-mongo.sh --env-file environments/dev.env >> $REPO/backups/backup-cron.log 2>&1 $MARKER"

CURRENT="$(crontab -l 2>/dev/null || true)"
FILTERED="$(printf '%s\n' "$CURRENT" | grep -v "ai-healthcare-sim backup-mongo" || true)"
if [ "$REMOVE" -eq 1 ]; then
  printf '%s\n' "$FILTERED" | crontab -
  echo "backup cron removed"
  exit 0
fi
printf '%s\n%s\n' "$FILTERED" "$LINE" | crontab -
echo "backup cron installed:"
crontab -l | grep "ai-healthcare-sim backup-mongo"
echo "(log: $REPO/backups/backup-cron.log)"
