# Pull request checklist (paste into PR body)

- [ ] `bash scripts/security-scan.sh` PASS (paste counts)
- [ ] `python3 scripts/compose-lint.py` 0 fail (paste summary)
- [ ] `bash scripts/check-outbound.sh` PASS (sole-ingress + no-internet proof)
- [ ] `bash scripts/infra-plan.sh --tag <sha>` artifact + SHA256SUMS committed
- [ ] Affected demo re-run (smoke / workload / pipeline / incident) + evidence log
- [ ] Docs touched in the same change (no new drift — see `REVIEW-02.md` method)
- [ ] No secrets in diff (`gitleaks` git mode clean, placeholders only)
