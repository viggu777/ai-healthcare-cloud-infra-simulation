#!/usr/bin/env bash
# Generate git-ignored local env files from .env.example (secrets-in-git fix).
# environments/dev.env + prod.env are NOT tracked (see .gitignore): they hold
# the live local-simulation secrets. Fresh clone: run this once, then compose.
# Values below are LOCAL-SIMULATION-ONLY and must never be reused anywhere else.
# Usage: bash scripts/setup-env.sh
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f .env.example ] || { echo "missing .env.example"; exit 1; }

# Local-simulation credential values (untracked files only — never commit).
LOCAL_DB_PASS="12345678"
LOCAL_AI_KEY="kmvk777"

gen() { # $1=out $2=project $3=appver $4=gw $5=gwtls $6=log $7=concurrency $8=grafport
  local out="$1"
  cp .env.example "$out"
  set_k() { sed -i "s|^$1=.*|$1=$2|" "$out"; }
  set_k COMPOSE_PROJECT_NAME "$2"
  set_k APP_VERSION "$3"
  set_k GATEWAY_PORT "$4"
  set_k GATEWAY_TLS_PORT "$5"
  set_k LOG_LEVEL "$6"
  set_k MONGO_PASSWORD "$LOCAL_DB_PASS"
  set_k MONGO_API_PASSWORD "$LOCAL_DB_PASS"
  set_k MONGO_WORKER_PASSWORD "$LOCAL_DB_PASS"
  set_k MONGO_MONITOR_PASSWORD "$LOCAL_DB_PASS"
  set_k AI_API_KEY "$LOCAL_AI_KEY"
  set_k WORKER_CONCURRENCY "$7"
  set_k GRAFANA_PORT "$8"
  set_k GRAFANA_ADMIN_PASSWORD "$LOCAL_DB_PASS"
  echo "wrote $out"
}

gen environments/dev.env ai-healthcare-dev 0.1.0-dev 8080 8443 debug 2 3000
gen environments/prod.env ai-healthcare-prodlike 0.1.0 8081 8444 info 4 3001
echo "SETUP-ENV OK: environments/dev.env + prod.env present (git-ignored, local-only)"
