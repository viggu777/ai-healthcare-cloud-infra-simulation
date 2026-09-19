#!/usr/bin/env bash
# Infra plan artifact (IaC recreation proof, PRD §6).
# Saves: (1) compose resolved config per env, (2) terraform file lint
# (offline, no provider needed), (3) resource inventory.
# Output: docs/infra-plan/<tag>/ (checked into evidence, hashed for audit).
# Usage: bash scripts/infra-plan.sh [--tag <tag>] [--env-file environments/dev.env]
set -euo pipefail
cd "$(dirname "$0")/.."
export DOCKER_CONFIG="${DOCKER_CONFIG:-/tmp/docker-nocreds}"
TAG="local-$(date +%Y%m%d-%H%M%S)"
ENV_FILE="environments/dev.env"
while [ $# -gt 0 ]; do case "$1" in --tag=*) TAG="${1#*=}"; shift;; --tag) TAG="$2"; shift 2;; --env-file=*) ENV_FILE="${1#*=}"; shift;; --env-file) ENV_FILE="$2"; shift 2;; *) shift;; esac; done
OUT="docs/infra-plan/$TAG"
mkdir -p "$OUT"
echo "infra plan -> $OUT"
docker compose --env-file environments/dev.env config >"$OUT/compose-dev.yml" 2>/dev/null
docker compose --env-file environments/prod.env -f docker-compose.yml -f docker-compose.prod.yml config >"$OUT/compose-prod.yml" 2>/dev/null
docker compose --env-file "$ENV_FILE" config --services | sort >"$OUT/services.txt"
docker compose --env-file "$ENV_FILE" config --volumes 2>/dev/null | sort >"$OUT/volumes.txt" || true
# Terraform offline lint: balanced braces + required blocks present (no binary needed).
python3 - "$OUT" <<'PY'
import sys, pathlib, re
out = pathlib.Path(sys.argv[1])
tfs = list(pathlib.Path("terraform").glob("*.tf"))
report = [f"terraform files: {[p.name for p in tfs]}"]
ok = True
for p in tfs:
    t = p.read_text()
    if t.count("{") != t.count("}"):
        report.append(f"[FAIL] {p.name} unbalanced braces"); ok = False
    else:
        report.append(f"[PASS] {p.name} braces balanced ({t.count('{')} blocks)")
for need in ['resource "terraform_data" "network_private"', 'resource "terraform_data" "api"']:
    found = any(need in p.read_text() for p in tfs)
    report.append(f"[{'PASS' if found else 'FAIL'}] contains {need}")
    ok = ok and found
(pathlib.Path(out) / "terraform-lint.txt").write_text("\n".join(report) + "\n")
print("\n".join(report))
sys.exit(0 if ok else 1)
PY
sha256sum "$OUT"/* >"$OUT/SHA256SUMS"
cat "$OUT/SHA256SUMS"
echo "INFRA-PLAN OK: $OUT"
