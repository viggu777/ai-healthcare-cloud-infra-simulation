#!/usr/bin/env bash
# Phase 1 smoke test — gateway-only public access, private services isolated.
set -euo pipefail
GW="${GATEWAY_URL:-http://localhost:8080}"
echo "== gateway health =="
curl -fsS "$GW/health"; echo
echo "== api ready via gateway =="
curl -fsS "$GW/ready"; echo
echo "== create appointment =="
curl -fsS -X POST "$GW/appointments" -H 'Content-Type: application/json' \
  -d '{"patient":"smoke-patient","doctor":"dr-smoke"}'; echo
sleep 3
echo "== list appointments =="
curl -fsS "$GW/appointments?limit=3"; echo
echo "== metrics =="
curl -fsS "$GW/metrics"; echo
echo "SMOKE OK"
