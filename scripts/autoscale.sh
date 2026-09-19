#!/usr/bin/env bash
# Queue-depth autoscaler (manual HPA stand-in, PRD §15).
# Polls api_queue_depth via gateway /metrics and scales workers linearly
# (measured ~3 jobs/s/worker in RESILIENCE.md §3).
# Policy: depth >15 (QueueBacklog threshold) -> scale up (max 4);
# depth ==0 for 2 consecutive polls -> scale down to 1 (min 1).
# Usage: bash scripts/autoscale.sh [--env-file environments/dev.env] [--once] [--interval 30]
set -euo pipefail
cd "$(dirname "$0")/.."
export DOCKER_CONFIG="${DOCKER_CONFIG:-/tmp/docker-nocreds}"
ENV_FILE="environments/dev.env"; ONCE=0; INTERVAL=30; GW="http://localhost:8080"
while [ $# -gt 0 ]; do case "$1" in
  --env-file=*) ENV_FILE="${1#*=}"; shift;; --env-file) ENV_FILE="$2"; shift 2;;
  --once) ONCE=1; shift;; --interval=*) INTERVAL="${1#*=}"; shift;; --interval) INTERVAL="$2"; shift 2;;
  *) shift;; esac; done
[[ "$ENV_FILE" == *prod* ]] && GW="http://localhost:8081"
# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a
idle_streak=0
loop(){
  qd="$(curl -fsS -m 5 "$GW/metrics" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('queue_depth',-1))" 2>/dev/null || echo -1)"
  workers="$(docker compose --env-file "$ENV_FILE" ps worker --format '{{.Name}}' 2>/dev/null | wc -l)"
  echo "$(date -u +%H:%M:%S) queue_depth=$qd workers=$workers"
  if [ "$qd" -gt 15 ] && [ "$workers" -lt 4 ]; then
    echo "  -> scaling up to $((workers+1)) (backlog above alert threshold)"
    docker compose --env-file "$ENV_FILE" up -d --scale "worker=$((workers+1))" --no-recreate 2>&1 | tail -1
    idle_streak=0
  elif [ "$qd" -eq 0 ]; then
    idle_streak=$((idle_streak+1))
    if [ "$idle_streak" -ge 2 ] && [ "$workers" -gt 1 ]; then
      echo "  -> scaling down to $((workers-1)) (drained)"
      docker compose --env-file "$ENV_FILE" up -d --scale "worker=$((workers-1))" --no-recreate 2>&1 | tail -1
      idle_streak=0
    fi
  else idle_streak=0; fi
}
if [ "$ONCE" -eq 1 ]; then loop; else while true; do loop; sleep "$INTERVAL"; done; fi
