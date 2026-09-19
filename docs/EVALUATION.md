# Automated Evaluation Guide (clone-and-review pipeline)

Repo is public: `https://github.com/viggu777/ai-healthcare-cloud-infra-simulation`.
One command reproduces every machine-checkable claim (needs Ubuntu + Docker):

```bash
git clone https://github.com/viggu777/ai-healthcare-cloud-infra-simulation.git
cd ai-healthcare-cloud-infra-simulation
bash scripts/evaluate.sh                 # full gates, exits 0 iff all pass
bash scripts/evaluate.sh --quick         # same minus image-pull gates
bash scripts/evaluate.sh --output result.json   # machine-readable JSON summary
```

`evaluate.sh` assumes NOTHING pre-built: it generates the git-ignored gateway
TLS cert, lints, unit-tests, validates all three compose configs, builds the 5
custom images, brings the stack up, waits for `/ready`, then runs smoke,
compose-lint, outbound proof, security scan, supply-chain statics, infra-plan,
and the Prometheus target probe — printing `[PASS]/[FAIL]` lines plus a final
`EVALUATE-JSON:` object (`{results:[{name,status,detail}], summary:{pass,fail}}`).
CI (`.github/workflows/pipeline.yml`) runs the same stages on every push.

## Requirement → evidence map (PRD v2.0)

| PRD § | Claim | Verify (command) | Expect |
|---|---|---|---|
| Setup | Fresh clone builds and serves | `bash scripts/gen-gateway-cert.sh && docker compose --env-file environments/dev.env up --build -d && curl -fsS http://localhost:8080/ready` | `{"ready":true,…}` |
| §3 | Mock services behind sole gateway | `bash scripts/check-outbound.sh` | `6 passed, 0 failed` (`:8001` refused, `internal:true`) |
| §5 | MongoDB persists, queue buffers | `GATEWAY_URL=http://localhost:8080 bash scripts/smoke.sh` | `SMOKE OK` |
| §9 | Secrets via env, least-privilege users | `docker compose --env-file environments/dev.env exec -T db mongosh --quiet -u monitor_user -p dev_monitor_only_change_me --authenticationDatabase admin --eval "db.getSiblingDB('healthcare').appointments.findOne()"` | `not authorized` |
| §9 | Secret rotation without outage | `bash scripts/rotate-secrets.sh --which ai-key` | `ROTATE OK` |
| §10 | Container hardening | `python3 scripts/compose-lint.py` | `81 pass, 0 fail, 4 warn` (documented exceptions, `docs/SECURITY.md`) |
| §10 | Vulnerability + secret gates | `bash scripts/security-scan.sh` | `RESULT: 32 passed, 0 failed` |
| §11 | Pipeline + rollback + traceability | `.github/workflows/pipeline.yml` (green on push); local twin `bash scripts/pipeline.sh` | CI green; `docs/pipeline-evidence/` logs |
| §13 | Resource graph without cloud | `bash scripts/infra-plan.sh --tag <sha>` | `INFRA-PLAN OK: docs/infra-plan/<tag>` (+ `terraform/` doc-only graph) |
| §15 | Scaling measured | `docs/RESILIENCE.md` §3–4 + `bash scripts/autoscale.sh --once` | worker linear 2.2×; API window-pin documented 44/0 |
| §16 | Metrics/health/dashboard | Prometheus targets probe in `evaluate.sh` | `8 8`; Grafana 19 panels (`monitoring/grafana/dashboards/healthcare.json`) |
| §17 | Alerting (14 rules, incl. AI/EHR) | `docker compose --env-file environments/dev.env exec -T prometheus wget -qO- http://localhost:9090/api/v1/rules \| python3 -c "import json,sys; print(sum(len(g['rules']) for g in json.load(sys.stdin)['data']['groups']))"` | `14` |
| §18 | Incident drills | `docs/INCIDENTS.md` (INC-01/02/03 with fire→resolve transcripts) | 3 lifecycles |
| §19 | Backup/restore drilled | `bash scripts/backup-volumes.sh --out backups/state-manual && bash scripts/verify-backup.sh backups/state-manual` | `STATE-BACKUP OK` + `8/8 OK` |
| §22 | FOSS-only, costed | `docs/COST.md`, `docs/sbom/*.spdx.json` (syft), digest pins in compose | $0 + SBOM evidence |
| §26 | Out-of-scope honesty | `docs/DEMO.md` + `docs/TARGET_ARCHITECTURE.md` §14 | 5 deviations listed |
| §31 | AI-use disclosure | `docs/AI-USAGE.md` | tool vs human-verified split |

Live numbers above were re-verified 2026-09-19 (`security-scan 32/0`,
`compose-lint 81/0/4`, `outbound 6/0`, `smoke OK` both envs, `8/8` targets up).
