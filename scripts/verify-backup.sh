#!/usr/bin/env bash
# Verify a state backup's integrity without touching live state (PRD §19).
# Usage: bash scripts/verify-backup.sh <backup-dir>
set -euo pipefail
cd "$(dirname "$0")/.."
B="${1:?usage: bash scripts/verify-backup.sh <backup-dir>}"
[ -f "$B/SHA256SUMS" ] || { echo "no SHA256SUMS in $B"; exit 1; }
(cd "$B" && sha256sum -c SHA256SUMS)
echo "VERIFY OK: all artifacts intact in $B"
ls -lh "$B"
