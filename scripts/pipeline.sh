#!/usr/bin/env bash
# Phase 3 — DevSecOps pipeline (local runnable equivalent of .github/workflows/pipeline.yml).
#
# Stages, in order (mirrors TARGET_ARCHITECTURE §7 / docs/CICD.md):
#   lint → unit → security (scripts/security-scan.sh AS-IS + scripts/trivy-gate.sh)
#     → build (SHA-tagged) → deploy dev → health gate (/ready via gateway,
#     scripts/smoke.sh is the baseline check) → workload → promote prod-like
#     → post-promote health check → rollback to previous tag on failure at any
#     post-build stage.
#
# Which artifact was chosen and why: BOTH exist. `.github/workflows/pipeline.yml`
# is the CI definition (runs on push/PR with github.sha tags). This script is the
# locally-executed equivalent — it is the demonstrated artifact because this repo
# has no git remote and no runner minutes; it implements the identical stage order,
# the identical gates, and the identical rollback semantics against the same
# Compose files. docs/CICD.md records both demonstrations with logs.
#
# Image tagging: every built image is tagged with the run tag, which is the git
# SHA when run inside a git checkout (`git rev-parse --short HEAD`, same value
# CI uses via github.sha) and `local-<timestamp>` otherwise. A semver alias from
# the env file is kept alongside so humans keep a stable reference; the running
# containers always carry the exact run tag (see traceability table at the end).
#
# Rollback: before touching an environment, the currently deployed tag is
# snapshotted. Any failure at/after `build` redeploys that previous tag and
# re-checks the health gate, so an unhealthy version never keeps serving.
# There are intentionally NO --skip flags for lint/unit/security: gates that can
# be skipped are not gates.
#
# Usage:
#   bash scripts/pipeline.sh [--tag <tag>] [--workload <N>] [--no-workload]
#                           [--health-timeout <seconds>]
# Exit codes: 0 = promoted to prod-like healthy; 1 = blocked/rolled back (see log).
set -euo pipefail
cd "$(dirname "$0")/.."

export DOCKER_CONFIG="${DOCKER_CONFIG:-/tmp/docker-nocreds}"
DEV_ENV="environments/dev.env"
PROD_ENV="environments/prod.env"
DEV_GW="http://localhost:8080"
PROD_GW="http://localhost:8081"
WORKLOAD_N="10"
HEALTH_TIMEOUT="120"
TAG_ARG=""

while [ $# -gt 0 ]; do
  case "$1" in
    --tag=*) TAG_ARG="${1#*=}"; shift ;;
    --tag) TAG_ARG="$2"; shift 2 ;;
    --workload=*) WORKLOAD_N="${1#*=}"; shift ;;
    --workload) WORKLOAD_N="$2"; shift 2 ;;
    --no-workload) WORKLOAD_N="0"; shift ;;
    --health-timeout=*) HEALTH_TIMEOUT="${1#*=}"; shift ;;
    --health-timeout) HEALTH_TIMEOUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^# Usage/p' "$0"; echo; grep -E '^#   ' "$0"; exit 0 ;;
    *) echo "unknown arg: $1 (see --help)"; exit 2 ;;
  esac
done

if [ -n "$TAG_ARG" ]; then
  RUN_TAG="$TAG_ARG"
elif GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null)"; then
  RUN_TAG="$GIT_SHA"
else
  echo "WARNING: no git SHA available (.git missing?) — falling back to timestamp tag. Auditability degraded." >&2
  RUN_TAG="local-$(date +%Y%m%d-%H%M%S)"
fi

EVIDENCE_DIR="docs/pipeline-evidence"
mkdir -p "$EVIDENCE_DIR"
LOG="$EVIDENCE_DIR/pipeline-$RUN_TAG.log"
exec > >(tee "$LOG") 2>&1

STAGE=""
DEPLOYING_ENV_FILE=""
DEPLOYING_PREV_TAG=""
SECURITY_OK=0 # Phase 4: 1 once security-scan.sh + trivy gate have passed this run

banner() { echo ""; echo "===== [pipeline:$RUN_TAG] STAGE: $1 ====="; }
set_stage() { STAGE="$1"; banner "$1"; }

# Tag currently deployed in an env (empty if the env was never deployed).
current_tag() { # $1=env-file $2=service
  local cid img
  cid="$(docker compose --env-file "$1" ps -q "$2" 2>/dev/null || true)"
  if [ -z "$cid" ]; then echo ""; return 0; fi
  img="$(docker inspect "$cid" --format '{{.Config.Image}}' 2>/dev/null || echo '')"
  echo "${img##*:}"
}

health_gate() { # $1=gw-url $2=timeout-s $3=label
  local gw="$1" timeout="$2" label="$3" waited=0 body
  echo "health gate ($label): polling $gw/ready (timeout ${timeout}s)…"
  while [ "$waited" -lt "$timeout" ]; do
    if body="$(curl -fsS -m 5 "$gw/ready" 2>/dev/null)"; then
      if printf '%s' "$body" | python3 -c "import json,sys; sys.exit(0 if json.load(sys.stdin).get('ready') is True else 1)" 2>/dev/null; then
        echo "health gate ($label): READY after ~${waited}s — $body"
        return 0
      else
        echo "  …not ready yet (~${waited}s): $body"
      fi
    else
      echo "  …no response yet (~${waited}s)"
    fi
    sleep 5; waited=$((waited+5))
  done
  echo "health gate ($label): TIMEOUT after ${timeout}s waiting for $gw/ready"
  return 1
}

rollback() { # uses DEPLOYING_ENV_FILE / DEPLOYING_PREV_TAG
  local env_file="$DEPLOYING_ENV_FILE" prev="$DEPLOYING_PREV_TAG" gw
  if [ "$env_file" = "$DEV_ENV" ]; then gw="$DEV_GW"; else gw="$PROD_GW"; fi
  echo ""
  echo "!!!!! ROLLBACK ($env_file): stage '$STAGE' failed — restoring previous tag '${prev:-<none>}'"
  if [ -n "$prev" ]; then
    APP_VERSION="$prev" docker compose --env-file "$env_file" up -d
    if health_gate "$gw" 60 "rollback-verify"; then
      echo "ROLLBACK OK: previous tag '$prev' serving again on $gw"
    else
      echo "ROLLBACK WARNING: previous tag redeployed but health gate still failing — operator needed"
    fi
  else
    docker compose --env-file "$env_file" down
    echo "ROLLBACK: no previous deployment existed — environment stopped (nothing unhealthy left serving)"
  fi
}

die() { # $1=message — roll back the env under deployment (if any) and exit 1
  echo ""
  echo "##### PIPELINE BLOCKED at stage '$STAGE': $1"
  if [ -n "$DEPLOYING_ENV_FILE" ]; then rollback; fi
  push_pipeline_metrics 0
  echo "##### RESULT: FAIL (see $LOG)"
  exit 1
}

# Phase 4: push run status to pushgateway so Alertmanager rules
# (DeploymentFailed, SecurityScanFailed) and the Grafana dashboard reflect it.
# The push goes THROUGH the api container (node fetch over stdin) because
# pushgateway lives on the private internal net, unreachable from the host
# directly. Stdin (not argv) carries the payload: multiline argv gets truncated
# on the wire through `docker exec` (pushgateway 400 "unexpected end of input").
# Best-effort by design (|| true everywhere): monitoring must never break the pipeline.
push_pipeline_metrics() { # $1=run success (0|1)
  local ok="$1" ts payload cid
  ts="$(date +%s)"
  payload="$(printf 'pipeline_last_run_success %s\npipeline_last_run_timestamp_seconds %s\nsecurity_scan_last_success %s\n' "$ok" "$ts" "$SECURITY_OK")"
  cid="$(docker compose --env-file "$DEV_ENV" ps -q api 2>/dev/null || true)"
  if [ -n "$cid" ]; then
    printf '%s' "$payload" | docker exec -i "$cid" node -e \
      "let b='';process.stdin.on('data',d=>b+=d).on('end',()=>{fetch('http://pushgateway:9091/metrics/job/pipeline/instance/$RUN_TAG',{method:'PUT',headers:{'Content-Type':'text/plain'},body:b}).then(()=>console.log('pipeline metrics pushed')).catch(e=>console.log('pipeline metrics push skipped: '+e.message))});" 2>/dev/null || true
  else
    echo "(pushgateway push skipped: dev api not running)"
  fi
}

traceability() {
  echo ""
  echo "----- traceability: running image tags -----"
  echo "-- dev ($DEV_ENV) --"
  APP_VERSION="$RUN_TAG" docker compose --env-file "$DEV_ENV" ps --format 'table {{.Service}}\t{{.Image}}\t{{.Status}}' 2>/dev/null || true
  echo "-- prod-like ($PROD_ENV) --"
  APP_VERSION="$RUN_TAG" docker compose --env-file "$PROD_ENV" ps --format 'table {{.Service}}\t{{.Image}}\t{{.Status}}' 2>/dev/null || true
  echo "run tag: $RUN_TAG (git SHA when available; CI uses github.sha)"
}

echo "Phase 3 pipeline starting — run tag: $RUN_TAG"
echo "log: $LOG"

# ---- lint ----
set_stage "lint"
# P1.1: the gateway TLS mount must exist before compose touches it.
if [ ! -f gateway/tls/gateway.crt ]; then
  echo "  (gateway TLS cert missing — generating local self-signed cert)"
  bash scripts/gen-gateway-cert.sh
else
  echo "  [lint-ok] gateway TLS cert present"
fi
for f in services/api/server.js services/api/validate.js services/api/validate.test.js \
         services/ai-service/server.js services/worker/worker.js services/ehr-mock/server.js \
         services/alert-logger/server.js; do
  node --check "$f" || die "lint failed: $f"
  echo "  [lint-ok] $f"
done
docker compose --env-file "$DEV_ENV" config -q || die "compose config invalid (dev)"
docker compose --env-file "$PROD_ENV" config -q || die "compose config invalid (prod-like)"
echo "  [lint-ok] compose config dev + prod-like"

# ---- unit ----
set_stage "unit"
node --test services/api/validate.test.js || die "unit tests failed"

# ---- security (existing gate AS-IS — never reimplemented) ----
set_stage "security (security-scan.sh as-is)"
bash scripts/security-scan.sh || die "security-scan.sh gate failed"
set_stage "security (trivy app-dependency gate)"
echo "(binding trivy gate runs after build, on the newly built tag — see below)"

# ---- build ----
set_stage "build (tag: $RUN_TAG)"
APP_VERSION="$RUN_TAG" docker compose --env-file "$DEV_ENV" build api ai-service worker ehr-mock alert-logger \
  || die "image build failed"
# Keep a human-stable semver alias next to the exact run tag.
SEMVER_DEV="$(grep -E '^APP_VERSION=' "$DEV_ENV" | cut -d= -f2)"
for svc in api ai-service worker ehr-mock alert-logger; do
  docker tag "ai-healthcare/$svc:$RUN_TAG" "ai-healthcare/$svc:$SEMVER_DEV"
done
echo "built + dual-tagged (:$RUN_TAG exact, :$SEMVER_DEV alias):"
docker images --format '  {{.Repository}}:{{.Tag}} {{.Size}}' | grep -E "ai-healthcare.*($RUN_TAG|$SEMVER_DEV)" | sort -u

set_stage "security (trivy app-dependency gate on NEW images)"
bash scripts/trivy-gate.sh --tag "$RUN_TAG" || die "trivy gate tripped on newly built images"
SECURITY_OK=1

# ---- deploy dev ----
set_stage "deploy dev"
DEPLOYING_ENV_FILE="$DEV_ENV"
DEPLOYING_PREV_TAG="$(current_tag "$DEV_ENV" api)"
echo "previous dev tag: '${DEPLOYING_PREV_TAG:-<none>}'"
APP_VERSION="$RUN_TAG" docker compose --env-file "$DEV_ENV" up -d || die "dev deploy failed"

# ---- health gate dev ----
set_stage "health gate dev"
health_gate "$DEV_GW" "$HEALTH_TIMEOUT" "dev" || die "dev health gate failed"
GATEWAY_URL="$DEV_GW" bash scripts/smoke.sh || die "dev smoke failed"
if [ "$WORKLOAD_N" != "0" ]; then
  python3 scripts/workload.py "$DEV_GW" "$WORKLOAD_N" || die "dev workload failed"
fi
DEPLOYING_ENV_FILE=""; DEPLOYING_PREV_TAG=""
echo "dev stage complete — healthy on tag $RUN_TAG"

# ---- promote prod-like ----
set_stage "promote prod-like"
DEPLOYING_ENV_FILE="$PROD_ENV"
DEPLOYING_PREV_TAG="$(current_tag "$PROD_ENV" api)"
echo "previous prod-like tag: '${DEPLOYING_PREV_TAG:-<none>}'"
APP_VERSION="$RUN_TAG" docker compose --env-file "$PROD_ENV" up -d || die "prod-like deploy failed"

# ---- post-promote check ----
set_stage "post-promote health check"
health_gate "$PROD_GW" "$HEALTH_TIMEOUT" "prod-like" || die "prod-like health gate failed"
GATEWAY_URL="$PROD_GW" bash scripts/smoke.sh || die "prod-like smoke failed"
DEPLOYING_ENV_FILE=""; DEPLOYING_PREV_TAG=""

traceability
push_pipeline_metrics 1
echo ""
echo "##### RESULT: PASS — tag $RUN_TAG healthy in dev AND prod-like (log: $LOG)"
