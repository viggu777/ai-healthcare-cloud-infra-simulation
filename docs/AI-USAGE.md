# AI-Assisted Engineering Log (PRD §31)

AI tools permitted; candidate owns the result. This log records where AI
materially contributed vs. where engineering judgment was human-verified.

## Used

- **Architecture exploration**: AI drafted the initial public/private split
  and alert-threshold options; human chose `internal:true` + sole-gateway
  ingress after verifying Docker drops published ports on internal-only
  networks (recorded in `SPOF.md §4b`).
- **Implementation**: AI suggested nginx `resolver + variable proxy_pass`
  for the static-DNS skew (`RESILIENCE.md §4`); human verified with
  `nginx -t`, gateway reload, live `/health` probes, and a 40-request
  `--scale api=2` re-test that showed window-pinning (44/0) — so the log
  records a *partial* remediation with measured limits, not a full fix.
- **Troubleshooting**: AI proposed the Gitleaks self-contamination theory
  (stale `-v` report re-tripping scans); human confirmed via log diff and
  fixed with pre-scan deletion in `security-scan.sh`.
- **Documentation**: AI helped normalize stale gate counts and draft
  runbooks; human re-checked every claim against compose/source/live probes
  (`REVIEW-02.md` method).

## Not delegated

Security decisions (cap_drop exceptions R2/R3, OS-baseline acceptance R1),
rollback semantics, backup retention, incident root causes, and all demo
evidence were human-executed and human-verified. No AI-generated
infrastructure was applied without `security-scan.sh` + affected-demo
re-run in the same change.

## Reproducibility

Every AI suggestion above ends in a verifiable artifact:
`compose-lint` report, `nginx -t`, Prometheus targets/rules APIs,
`pipeline-*.log`, `INCIDENTS.md` timelines. An evaluator can re-run each
without trusting the AI output.
