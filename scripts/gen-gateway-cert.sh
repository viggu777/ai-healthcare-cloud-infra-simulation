#!/usr/bin/env bash
# P1.1 — Generate a self-signed TLS cert for the Nginx gateway (simulation only).
# The key is LOCAL-ONLY (CN=localhost, never a real secret) and lives in
# gateway/tls/ (git-ignored — never committed, so Gitleaks stays clean).
# Idempotent: refuses to overwrite an existing cert unless --force is given.
# Called automatically by scripts/pipeline.sh when the cert is missing.
set -euo pipefail
cd "$(dirname "$0")/.."

FORCE=0
if [ "${1:-}" = "--force" ]; then FORCE=1; fi

mkdir -p gateway/tls
if [ -f gateway/tls/gateway.crt ] && [ "$FORCE" -eq 0 ]; then
  echo "gateway/tls/gateway.crt exists — nothing to do (use --force to rotate)"
  exit 0
fi

openssl req -x509 -newkey rsa:2048 \
  -keyout gateway/tls/gateway.key -out gateway/tls/gateway.crt \
  -days 825 -nodes \
  -subj "/CN=localhost/O=ai-healthcare-sim-local" \
  -addext "subjectAltName=DNS:localhost,DNS:gateway,IP:127.0.0.1" 2>/dev/null
chmod 600 gateway/tls/gateway.key
echo "TLS cert ready: gateway/tls/gateway.crt (+ key, git-ignored, local-only)"
openssl x509 -in gateway/tls/gateway.crt -noout -subject -dates
