#!/usr/bin/env bash
# Phase 3 — Trivy CI gate (explicit --exit-code style gate on APP dependencies).
#
# Phase 2's scripts/security-scan.sh runs Trivy as a REPORT step: the Debian
# bookworm OS layer carries 52 HIGH / 4 CRITICAL findings with no upstream fix
# (docs/SECURITY.md R1, accepted + mitigated), so a blanket `--exit-code 1`
# would fail every build forever. This gate closes Phase 2's R5 instead:
# it FAILS (exit 1) on any HIGH/CRITICAL finding in APP dependencies
# (Trivy class `lang-pkgs`, i.e. the node-pkg results from our node_modules),
# while the OS-layer baseline is reported but non-blocking.
#
# Usage:
#   bash scripts/trivy-gate.sh [--env-file environments/dev.env] [--tag <image-tag>]
# Exit codes: 0 = no app-dependency HIGH/CRITICAL; 1 = gate tripped (blocks pipeline).
# FOSS only: aquasec/trivy image via Docker (same cache mount as security-scan.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

export DOCKER_CONFIG="${DOCKER_CONFIG:-/tmp/docker-nocreds}"
ENV_FILE="environments/dev.env"
TAG_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --env-file=*) ENV_FILE="${1#*=}"; shift ;;
    --env-file) ENV_FILE="$2"; shift 2 ;;
    --tag=*) TAG_OVERRIDE="${1#*=}"; shift ;;
    --tag) TAG_OVERRIDE="$2"; shift 2 ;;
    environments/*) ENV_FILE="$1"; shift ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac
done

if [ -n "$TAG_OVERRIDE" ]; then
  APP_VERSION="$TAG_OVERRIDE"
else
  APP_VERSION="$(grep -E '^APP_VERSION=' "$ENV_FILE" | cut -d= -f2 || echo 0.1.0-dev)"
fi

FAIL=0
EVIDENCE_TMP="$(mktemp -d)"
trap 'rm -rf "$EVIDENCE_TMP"' EXIT
echo "=== Trivy app-dependency gate (tag: $APP_VERSION; OS baseline non-blocking per SECURITY.md R1) ==="
for svc in api ai-service worker ehr-mock alert-logger; do
  img="ai-healthcare/$svc:$APP_VERSION"
  echo "-- $img"
  # P1.7 fix: never swallow a trivy failure into an empty pipe (an empty
  # document used to die inside json.load with no hint of the real cause,
  # e.g. a tag that was never built on this runner).
  scan_json="$(docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
      -v /tmp/opencode/trivycache:/root/.cache/ \
      aquasec/trivy:latest image --format json --severity HIGH,CRITICAL \
        --scanners vuln --no-progress "$img" 2>"$EVIDENCE_TMP/trivy-$svc.stderr" || true)"
  if [ -z "$scan_json" ]; then
    echo "   [GATE-ERROR] trivy produced no JSON for $img — did this tag get built on this host? (tail of trivy stderr:)"
    tail -5 "$EVIDENCE_TMP/trivy-$svc.stderr" || true
    FAIL=1
    continue
  fi
  result="$(printf '%s' "$scan_json" \
    | python3 -c "
import json, sys
d = json.load(sys.stdin)
app = os_total = 0
for r in d.get('Results', []) or []:
    n = len(r.get('Vulnerabilities') or [])
    if r.get('Class') == 'lang-pkgs':
        app += n
    else:
        os_total += n
print(f'{app} {os_total}')
")"
  # shellcheck disable=SC2086
  set -- $result
  app="$1"; osbase="$2"
  echo "   app-dependency (lang-pkgs) HIGH/CRITICAL: $app | OS-layer (accepted baseline R1): $osbase"
  if [ "$app" -gt 0 ]; then
    echo "   [GATE-TRIPPED] $svc has $app app-dependency HIGH/CRITICAL finding(s) — blocking"
    FAIL=1
  else
    echo "   [GATE-PASS] $svc app dependencies clean"
  fi
done

echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "TRIVY GATE: FAIL — app-dependency vulnerabilities must be fixed before deploy"
  exit 1
fi
echo "TRIVY GATE: PASS"
