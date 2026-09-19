# Supply-Chain Security (SBOM, signing, IaC scan, perf gate)

Beyond `security-scan.sh` (Gitleaks + Trivy report + compose lint) and
`trivy-gate.sh` (blocking on app deps), `scripts/supply-chain.sh` adds:

## 1. SBOM (`syft`, informative)

Per-image SPDX JSON in `docs/sbom/`. Answers "what is inside this image?"
for auditors without gating every build on inventory churn.

## 2. IaC scan (`checkov`, gate)

Scans `terraform/` for HIGH/CRITICAL misconfigurations (open ingress,
unencrypted state, wildcard IAM). Compose posture stays in
`compose-lint.py` (sole-ingress, `internal:true`, no privileged/caps).

## 3. Signing (`cosign`, documented — not executed locally)

Keyless signing needs OIDC + a registry; this local Compose simulation has
neither. The verifiable substitute executed here: digest-pinned bases +
per-run image digests recorded by `infra-plan.sh` (`SHA256SUMS`) and the
pipeline traceability table. Promoting to a registry later adds one step:
`cosign sign --yes $DIGEST` in `.github/workflows/pipeline.yml` after build.

## 4. Perf gate (`k6`, blocking)

`k6/smoke.js` thresholds (`http_req_failed rate<0.01`, `p(95)<500ms`) run
against the dev gateway post-deploy. A latency/error regression blocks
promotion the same way a failed health gate does — performance is measured,
per PRD §15, not assumed.
