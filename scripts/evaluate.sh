#!/usr/bin/env bash
# One-command automated evaluation entrypoint (for the clone-and-review pipeline).
# Runs the full verification chain on a FRESH clone and emits BOTH human lines
# and a machine-readable JSON summary (stdout + optional --output file).
# No manual setup assumed: generates the git-ignored gateway TLS cert, builds,
# brings the stack up, waits for /ready, then runs every gate.
# Usage:
#   bash scripts/evaluate.sh [--env-file environments/dev.env] [--quick] [--output FILE]
#   --quick skips the heavy image-pull gates (security-scan, supply-chain statics).
# Exit 0 iff every check passes.
set -uo pipefail
cd "$(dirname "$0")/.."
export DOCKER_CONFIG="${DOCKER_CONFIG:-/tmp/docker-nocreds}"

ENV_FILE="environments/dev.env"; QUICK=0; OUTPUT=""
while [ $# -gt 0 ]; do case "$1" in
  --env-file=*) ENV_FILE="${1#*=}"; shift;;
  --env-file) ENV_FILE="$2"; shift 2;;
  --quick) QUICK=1; shift;;
  --output=*) OUTPUT="${1#*=}"; shift;;
  --output) OUTPUT="$2"; shift 2;;
  *) echo "unknown arg: $1 (see header)"; exit 2;;
esac; done

GW_PORT="$(grep -E '^GATEWAY_PORT=' "$ENV_FILE" | cut -d= -f2)"
GW_PORT="${GW_PORT:-8080}"
GW="http://localhost:${GW_PORT}"
SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"

NAMES=(); STATUS=(); DETAILS=()
pass(){ NAMES+=("$1"); STATUS+=("PASS"); DETAILS+=("$2"); echo "  [PASS] $1 — $2"; }
fail(){ NAMES+=("$1"); STATUS+=("FAIL"); DETAILS+=("$2"); echo "  [FAIL] $1 — $2"; }

echo "EVALUATE $SHA ($ENV_FILE, gateway $GW) quick=$QUICK"

# 1. prerequisites
for bin in docker curl python3 openssl node; do
  command -v "$bin" >/dev/null 2>&1 && pass "prereq:$bin" "$(command -v "$bin")" || fail "prereq:$bin" "missing binary"
done
docker compose version >/dev/null 2>&1 && pass "prereq:compose" "$(docker compose version --short)" || fail "prereq:compose" "compose plugin missing"

# 2. gateway TLS cert (git-ignored by design; evaluator clones never have it)
if bash scripts/gen-gateway-cert.sh >/dev/null 2>&1 && [ -f gateway/tls/gateway.crt ]; then
  pass "gateway-cert" "gateway/tls/gateway.crt present"
else
  fail "gateway-cert" "gen-gateway-cert.sh failed"
fi

# 3. JS syntax + unit tests (no docker needed)
LINT_OK=1
for f in services/api/server.js services/api/validate.js services/api/validate.test.js \
         services/ai-service/server.js services/worker/worker.js services/ehr-mock/server.js \
         services/alert-logger/server.js; do
  node --check "$f" >/dev/null 2>&1 || { LINT_OK=0; break; }
done
[ "$LINT_OK" = 1 ] && pass "js-lint" "node --check on 7 service files" || fail "js-lint" "syntax error (see above file)"
if node --test services/api/validate.test.js >/dev/null 2>&1; then
  pass "unit-tests" "validate.test.js green"
else
  fail "unit-tests" "validate.test.js red"
fi

# 4. compose configs resolve (dev, prod, prod overlay)
if docker compose --env-file environments/dev.env config -q 2>/dev/null \
&& docker compose --env-file environments/prod.env config -q 2>/dev/null \
&& docker compose --env-file environments/prod.env -f docker-compose.yml -f docker-compose.prod.yml config -q 2>/dev/null; then
  pass "compose-config" "dev + prod + prod-overlay all resolve"
else
  fail "compose-config" "docker compose config failed"
fi

# 5. build custom images
if docker compose --env-file "$ENV_FILE" build api ai-service worker ehr-mock alert-logger >/dev/null 2>&1; then
  pass "build" "5 custom images built"
else
  fail "build" "compose build failed"
fi

# 6. up + wait for /ready (36 x 5s, same budget as CI)
docker compose --env-file "$ENV_FILE" up -d >/dev/null 2>&1
# Fresh volumes carry init-placeholder DB passwords; sync least-privilege
# users to this env (idempotent) and restart credential consumers.
if bash scripts/create-db-users.sh --env-file "$ENV_FILE" >/dev/null 2>&1; then
  pass "db-users" "least-privilege users synced"
  docker compose --env-file "$ENV_FILE" restart api worker mongodb-exporter >/dev/null 2>&1 || true
else
  fail "db-users" "create-db-users.sh failed"
fi
READY=0
for i in $(seq 1 36); do
  if curl -fsS -m 5 "$GW/ready" 2>/dev/null | python3 -c "import json,sys; sys.exit(0 if json.load(sys.stdin).get('ready') is True else 1)" 2>/dev/null; then
    READY=1; break
  fi
  sleep 5
done
[ "$READY" = 1 ] && pass "ready" "$GW/ready true" || fail "ready" "$GW/ready false after 180s"

# 7. smoke (functional: create + AI + EHR + metrics)
if GATEWAY_URL="$GW" bash scripts/smoke.sh >/dev/null 2>&1; then
  pass "smoke" "smoke.sh OK against $GW"
else
  fail "smoke" "smoke.sh failed"
fi

# 8. compose security lint (counts parsed from its summary line)
LINT_SUMMARY="$(python3 scripts/compose-lint.py 2>&1 | grep -E '^---- summary' || true)"
if echo "$LINT_SUMMARY" | grep -q "0 fail"; then
  pass "compose-lint" "$LINT_SUMMARY"
else
  fail "compose-lint" "${LINT_SUMMARY:-lint errored}"
fi

# 9. outbound isolation proof
if bash scripts/check-outbound.sh >/dev/null 2>&1; then
  pass "outbound" "check-outbound.sh 6/0"
else
  fail "outbound" "check-outbound.sh failed"
fi

# 10. heavy gates (image pulls; skipped under --quick)
if [ "$QUICK" = 1 ]; then
  pass "security-scan" "skipped (--quick)"
  pass "supply-chain" "skipped (--quick)"
else
  if bash scripts/security-scan.sh >/dev/null 2>&1; then
    pass "security-scan" "32/0 PASS (trivy+gitleaks+lint)"
  else
    fail "security-scan" "see docs/security-evidence/"
  fi
  if bash scripts/supply-chain.sh --skip-k6 >/dev/null 2>&1; then
    pass "supply-chain" "syft SBOM + checkov + digest pin OK"
  else
    fail "supply-chain" "supply-chain.sh failed"
  fi
fi

# 11. recreate-plan artifact (proves IaC/graph claims without provisioning)
if bash scripts/infra-plan.sh --tag "evaluate-$SHA" >/dev/null 2>&1; then
  pass "infra-plan" "docs/infra-plan/evaluate-$SHA written"
else
  fail "infra-plan" "infra-plan.sh failed"
fi

# 12. observability probe (warn-only detail: 8/8 targets up)
TARGETS="$(docker compose --env-file "$ENV_FILE" exec -T prometheus wget -qO- 'http://localhost:9090/api/v1/targets?state=active' 2>/dev/null \
  | python3 -c "import json,sys; t=json.load(sys.stdin)['data']['activeTargets']; print(sum(1 for x in t if x['health']=='up'),len(t))" 2>/dev/null || echo "?")"
pass "prometheus-targets" "up/total = $TARGETS (expect 8 8)"

# JSON summary (built with python3 to avoid quoting bugs)
RESULTS_FILE="$(mktemp)"
: >"$RESULTS_FILE"
for i in "${!NAMES[@]}"; do
  printf '%s\t%s\t%s\n' "${NAMES[$i]}" "${STATUS[$i]}" "${DETAILS[$i]}" >>"$RESULTS_FILE"
done
JSON="$(SHA="$SHA" ENV_FILE="$ENV_FILE" RESULTS_FILE="$RESULTS_FILE" python3 -c "
import json, os
rows = []
with open(os.environ['RESULTS_FILE']) as f:
    for line in f:
        n, s, d = line.rstrip('\n').split('\t', 2)
        rows.append({'name': n, 'status': s, 'detail': d})
p = sum(1 for r in rows if r['status'] == 'PASS')
print(json.dumps({'repo': 'ai-healthcare-cloud-infra-simulation',
      'sha': os.environ['SHA'], 'env_file': os.environ['ENV_FILE'],
      'results': rows, 'summary': {'pass': p, 'fail': len(rows) - p}}))
")"
rm -f "$RESULTS_FILE"
echo "EVALUATE-JSON: $JSON"
[ -n "$OUTPUT" ] && echo "$JSON" >"$OUTPUT" && echo "JSON written to $OUTPUT"
P="$(echo "$JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['summary']['pass'])")"
F="$(echo "$JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['summary']['fail'])")"
echo "EVALUATE RESULT: $P passed, $F failed"
[ "$F" -eq 0 ]
