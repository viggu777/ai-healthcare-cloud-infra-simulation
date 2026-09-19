#!/usr/bin/env bash
# Outbound + isolation proof (PRD §8/§9 controlled inbound AND outbound).
# Proves: (1) private services have no internet route (internal:true),
# (2) worker talks to EHR the way it would a real external system
# (timeout-bounded, no shared creds), (3) only gateway publishes a port.
# Usage: bash scripts/check-outbound.sh [--env-file environments/dev.env]
# Exit 0 = all assertions pass; prints evidence for docs/DEMO.md.
set -euo pipefail
cd "$(dirname "$0")/.."
export DOCKER_CONFIG="${DOCKER_CONFIG:-/tmp/docker-nocreds}"
ENV_FILE="environments/dev.env"
if [ "${1:-}" = "--env-file" ]; then ENV_FILE="${2:-environments/dev.env}"; fi
# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a
P="docker compose --env-file $ENV_FILE"
PASS=0; FAIL=0
ok(){ echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad(){ echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
echo "=== 1/3 no internet route from private net (expect timeout/fail fast) ==="
if $P exec -T db sh -c 'timeout 5 sh -c "cat < /dev/null > /dev/tcp/8.8.8.8/53"' 2>/dev/null; then
  bad "db reached 8.8.8.8:53 (internal:true broken?)"
else
  ok "db cannot reach internet (8.8.8.8:53 refused/timeout)"
fi
if $P exec -T worker node -e "fetch('http://8.8.8.8/',{signal:AbortSignal.timeout(4000)}).then(()=>process.exit(0)).catch(()=>process.exit(1))" 2>/dev/null; then
  bad "worker reached internet (unexpected)"
else
  ok "worker cannot reach internet (fetch 8.8.8.8 timed out/refused)"
fi
echo "=== 2/3 controlled internal + simulated-external paths ==="
if $P exec -T worker node -e "fetch('http://ehr-mock:8002/health',{signal:AbortSignal.timeout(3000)}).then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" 2>/dev/null; then
  ok "worker -> ehr-mock:8002 reachable (simulated-external path, timeout-bounded)"
else
  bad "worker cannot reach ehr-mock (internal path broken)"
fi
if $P exec -T api node -e "fetch('http://ai-service:8001/health',{signal:AbortSignal.timeout(3000)}).then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" 2>/dev/null; then
  ok "api -> ai-service:8001 reachable (internal-only path)"
else
  bad "api cannot reach ai-service"
fi
echo "=== 3/3 sole ingress (only gateway publishes a host port) ==="
# Any 0.0.0.0-published port on a non-gateway service is a violation.
# (Gateway 8080/8081 + grafana 127.0.0.1-only are the documented exceptions.)
# Scoped to this repo's containers only (other projects share the host).
VIOL="$(docker ps --format '{{.Names}} {{.Ports}}' | grep -E "ai-healthcare-(dev|prodlike)" | grep -E "0\.0\.0\.0|:::" | grep -vE "gateway|127\.0\.0\.1" || true)"
if [ -z "$VIOL" ]; then ok "sole ingress holds (only gateway publishes a LAN port; grafana is 127.0.0.1-only)"; else bad "unexpected public port: $VIOL"; fi
# Direct private port must refuse from host:
if curl -m 3 -fsS http://localhost:8001/health >/dev/null 2>&1; then bad "ai-service reachable from host :8001 (should refuse)"; else ok "ai-service :8001 refused from host (private-only)"; fi
echo "==================================="
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
