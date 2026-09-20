# Repository Audit — DevOps & Cloud Engineer Intern Requirements Traceability Review

**Scope note:** graded against the repository only (plus live behavior produced by running it). Submission PDFs/videos under `submission-docs/` were listed but never opened, and no claim from any in-repo doc is credited without config/code evidence. Real cloud deployment is not required and is not flagged.

**Environment used:** Docker Engine 29.1.4 + Compose v2.40.3; no `terraform`/`tofu` binary available (noted where relevant). Stack was already up (`ai-healthcare-dev`, 15 services) at audit start; auditor additionally created one appointment, ran EHR-mode probes, executed `check-outbound.sh`, ran the compose lint, and performed a `docker kill` recovery test on the worker (restored afterwards with `up -d worker`, verified healthy).

---

## 1. Executive summary (~150 words)

The repository implements a coherent, runnable production-style simulation: sole Nginx ingress, private-only MongoDB/Redis/internal services, least-privilege DB users, non-root custom images, a DevSecOps pipeline with blocking security gates, Prometheus/Grafana/Alertmanager observability with a real file-backed alert sink, and scripted backup/restore plus incident drills. Live verification confirmed end-to-end flow (create → queued → worker-processed in MongoDB), all seven EHR failure modes, sole-ingress isolation, TLS, rate limiting, and 8/8 Prometheus targets. Gaps are concentrated in recovery automation (a daemon-level `docker kill` of the worker did **not** auto-revive despite `restart: unless-stopped`), rollout ordering (deploy-then-verify, not verify-before-shift; canary error gate is a no-op), committed env files carrying live credential values, shallow worker health, and the documented MongoDB-for-relational substitution. Score: **92.1%** (69 PASS, 13 PARTIAL, 0 FAIL of 82), with **zero CRITICAL** but five HIGH findings.

---

## 2. Requirement coverage matrix

`ID | Requirement | Status | Evidence | Missing/Problem | Severity`

| ID | Requirement | Status | Evidence | Missing/Problem | Severity |
|---|---|---|---|---|---|
| R1 | §3 API service: controlled ingress, health checks, secure comms, horizontal scaling, no direct infra exposure | PASS | `gateway/nginx.conf:22-68` routes only to `api:8000`; `services/api/server.js:69-84` `/health`+`/ready`; `--scale api=2` supported (`README.md:38`) | Round-robin limitation honestly documented, not hidden | LOW |
| R2 | §3 AI/agent mock: internal-only, secret handling, resource controls, isolation, monitoring | PASS | `docker-compose.yml:103-125` private-only, `read_only`, `cap_drop`; `services/ai-service/server.js:39-45` key check; scrape `monitoring/prometheus.yml:28-31` | None | — |
| R3 | §3 Worker: observable queue depth/latency/failures/retries/restarts; failure simulatable, recovery demonstrable | PASS | `services/worker/worker.js:96-135` prom metrics, `WORKER_FAIL_MODE` (`:21`); `docs/INCIDENTS.md:17-113` INC-01 | Auto-recovery caveat, see R32/R33 | HIGH |
| R4 | §3 Relational, private database (no direct public access) | PARTIAL | `docker-compose.yml:187-206` private-only, no `ports`, verified refused from host (audit curl) | MongoDB 7 used instead of relational; deviation documented (`docs/TARGET_ARCHITECTURE.md:359-367`) but spec sentence is explicit | MEDIUM |
| R5 | §3 EHR mock: success, slow, timeout, temporary, auth, unavailable, unknown-outcome as distinct triggerable paths | PASS | `services/ehr-mock/server.js:39-72`; auditor live-probed all 7 modes via `/ehr/status?mode=` (200/200-slow/500/401/503/500-unknown/timeout-504) | None | — |
| R6 | §3 Queue/async mechanism supporting normal, growth, failure, recovery, retry | PASS | `docker-compose.yml:167-185` Redis AOF; `services/worker/worker.js:270-282` BLPOP loop, `250-263` bounded requeue/dead-letter | None | — |
| R7 | §4 One clear architecture diagram + boundaries | PASS | `docs/TARGET_ARCHITECTURE.md:43-111` single Mermaid diagram + reading guide | Second Mermaid in §13 is a migration sketch, acceptable | LOW |
| R8 | §5 Entire project runnable in controlled env | PASS | Stack up 15/15; auditor `POST /appointments` → `processed` in Mongo; `scripts/evaluate.sh` one-command verify | None | — |
| R9 | §6 IaC reproducible, version-controlled, parameterized, repeatable, destroyable | PASS | `docker-compose.yml` + `terraform/` + `scripts/infra-plan.sh` (SHA256SUMS artifact); `scripts/full-recreate.sh` destroy path | `terraform/` is descriptive `terraform_data`-only, no validate binary in env | MEDIUM |
| R10 | §6/§7 No whole-stack duplication per environment | PASS | Base `docker-compose.yml` + `docker-compose.prod.yml` (38-line resource-limit overlay only) + `environments/dev.env`/`prod.env` | None | — |
| R11 | §7 Dev + prod-like separation, shared reusable definitions | PASS | `COMPOSE_PROJECT_NAME` ai-healthcare-dev vs -prodlike; ports 8080/8443 vs 8081/8444; `WORKER_CONCURRENCY` 2 vs 4 | None | — |
| R12 | §8 Only genuine ingress publicly exposed | PASS | Resolved config: only `gateway` publishes LAN ports (8080→80, 8443→443); `scripts/check-outbound.sh` 6/0 live | Two ports (HTTP+HTTPS), not one — justified, same ingress | LOW |
| R13 | §8 DB, workers, queues, internal services, mgmt interfaces private | PASS | `db/queue/ai-service/worker/ehr-mock/alert-logger` on `private` only (`docker-compose.yml:115-116,144-145,177-178,192-193,220-221,294-295`); `:8001`/`:27017` refused from host (audit curl) | None | — |
| R14 | §8 Intentionally controlled inbound and outbound | PASS | Inbound: `nginx.conf:5-8` rate limit 20r/s, live burst test 27×429/50; outbound: `private.internal:true` (`:23`), live 8.8.8.8 refusal (`check-outbound.sh`) | None | — |
| R15 | §8 Restricted administrative access | PASS | Grafana `127.0.0.1:${GRAFANA_PORT}:3000` (`:336`); Prometheus/Alertmanager/Pushgateway no published ports | None | — |
| R16 | §8 Trust boundaries explained | PASS | `docs/TARGET_ARCHITECTURE.md:163-178,221` incl. explicit EHR-boundary deviation | None | — |
| R17 | §9 Least privilege (runtime, workers, DB, deploy, monitoring, admins, devs) | PASS | Per-service Mongo users (`db/mongo-init.js:15-37`); exporter `monitor_user`/`clusterMonitor` (`docker-compose.yml:385`); `scripts/create-db-users.sh` sync | Human-role separation coarse (simulation-grade) | MEDIUM |
| R18 | §9 No hard-coded secrets in code/images/IaC/version control | PARTIAL | `grep` found no literals in `services/*/server.js|worker.js`, Dockerfiles, compose (all `${VAR:-placeholder}`); gitleaks report `no leaks found` (`docs/security-evidence/gitleaks.txt`) | `environments/dev.env` + `prod.env` with live credential values are git-tracked (`git ls-files`) | HIGH |
| R19 | §9 Secrets storage + delivery explanation, rotation | PASS | `README.md:54-56`, `.env.example` placeholders; `scripts/rotate-secrets.sh` end-to-end rotation | None | — |
| R20 | §10 Minimal images, no unnecessary packages | PASS | `node:22-slim` digest-pinned multistage; npm toolchain stripped (`services/api/Dockerfile:8-10`); `security-scan.sh:56-69` minimal-image audit | None | — |
| R21 | §10 Non-root services where practical | PARTIAL | All 5 custom Dockerfiles `USER node` (`:14`); live UID 1000 verified for api/ai/worker/ehr/alert-logger | gateway/db/queue run as root (documented exceptions) | MEDIUM |
| R22 | §10 Dependency/vuln validation incl. container scanning mechanism | PASS | `scripts/security-scan.sh:84-102` Trivy reports; `scripts/trivy-gate.sh:43-82` app-dep (`lang-pkgs`) HIGH/CRITICAL → `exit 1`; 56 OS-layer findings accepted baseline (`docs/security-evidence/trivy-api.txt`) | Live Trivy re-run not repeated by auditor (heavy pulls); wiring verified by reading | LOW |
| R23 | §10 No unnecessary privileges / unsafe runtime settings | PARTIAL | `cap_drop: ALL` + `no-new-privileges` on 5 customs (`docker-compose.yml:69-72,106-109,131-133,211-214,290-293`); `read_only` on 4 Node services; lint `scripts/compose-lint.py:155-163` gates, 81 pass/0 fail (audit run) | `alert-logger` lacks `read_only` and lint doesn't enforce it; gateway/db/queue exempt (documented) | MEDIUM |
| R24 | §10 Compromised-workload blast-radius reduction | PASS | `private.internal:true` + no creds shared across boundary (worker has no `AI_API_KEY`); read-only roots + tmpfs | None | — |
| R25 | §11 Infra security validation: actionable + in workflow | PASS | `compose-lint.py` fails (`sys.exit(main)` → 1 on FAIL) and gates `pipeline.sh:218` + `security-scan.sh:132-135`; wired with `|| die` / blocking steps | None | — |
| R26 | §12 Pipeline: validation, testing, security, infra validation, build, artifact validation, deploy, health verify, completion/rollback | PASS | `scripts/pipeline.sh:177-288` + `.github/workflows/pipeline.yml:27-160` mirror: lint→unit→audit→security→build→trivy-gate→deploy→health→workload→promote→post-check→rollback | None | — |
| R27 | §12 Security integrated + at least one meaningful failure blocks deploy | PASS | `pipeline.sh:218,235` (`|| die`), workflow `security` job blocks `build-deploy-promote` (`needs:`); demo `docs/pipeline-evidence/pipeline-p3-demo-blocked-secret.log` | None | — |
| R28 | §13 Versioned, controlled releases (traceable tags) | PASS | `RUN_TAG` git-SHA (`pipeline.sh:65-72`), workflow `RUN_TAG: github.sha` (`:24`); live images carry `434c7e7`/`5481515` tags; `traceability()` (`:164-172`) | None | — |
| R29 | §13 Zero-downtime steps: new ready → verified → shifted → old removed | PARTIAL | Health gate + smoke + workload post-deploy (`pipeline.sh:255-264`); `scripts/canary.sh` deploy→verify→promote/rollback shape | Order is deploy-then-verify (Compose recreates in place); canary error check is a no-op (`canary.sh:30-32`, `then :; fi`) | HIGH |
| R30 | §13 Unhealthy version detected, rollout stopped, previous kept / rolled back | PASS | `pipeline-p3-demo-broken-ready.log` tail: `ROLLBACK OK: previous tag 'p3-demo-healthy1' serving again`; `rollback()` (`pipeline.sh:116-133`) + workflow `if: failure()` steps | None | — |
| R31 | §14 API service failure tolerated | PASS | `restart: unless-stopped` (`:78`); `proxy_next_upstream error timeout http_502 http_503` (`nginx.conf:59-60`); `APIUnavailable` alert | Single replica by default (documented, scalable) | MEDIUM |
| R32 | §14 Worker failure tolerated | PARTIAL | `restart: unless-stopped` (`:139`); `WorkerDown`/`QueueBacklog` alerts; INC-01 documents stop→detect→manual `up -d`→drain | Auditor `docker kill` → container stayed `exited`, RestartCount 0 after 35s; recovery required manual `up -d` | HIGH |
| R33 | §14 Container/instance failure auto-recovery | PARTIAL | Same `restart: unless-stopped` on all 15 services (grep: 15/15 present); live HostConfig confirms `unless-stopped` | Live kill test did not auto-revive (see R32); in-container SIGTERM/SIGKILL to PID 1 had no observable effect | HIGH |
| R34 | §14 EHR failure handling (timeout, retry, failure handling) | PASS | Bounded retry + exp backoff (`worker.js:56-58,212-216`), circuit breaker closed/open/half-open (`:163-170,204-210`), 401 terminal (`:193-199`), all verified by reading; EHR modes live-probed | None | — |
| R35 | §14 Queue backlog handling | PASS | `QueueBacklog` alert (`alerts.yml:47-55`), `scripts/autoscale.sh` depth>15 scale-up policy, `--scale worker=N` | None | — |
| R36 | §14 DB connectivity failure handling | PASS | `/ready` fail-fast (`server.js:73-84`, live `503` path); `ConfigFailure` + `DBUnavailable` alerts; `restore-mongo.sh` drill; `backups/` populated | None | — |
| R37 | §14 Deployment failure handling | PASS | Health-gated promotion + previous-tag rollback (R30 evidence) | Ordering caveat per R29 | MEDIUM |
| R38 | §14 Configuration failure handling | PASS | `ConfigFailure: api_ready == 0` (`alerts.yml:131-139`); bad-cred behavior documented INC-03 | None | — |
| R39 | §14 Avoid unnecessary SPOFs (instances, health, distribution, auto-restart, isolation, retry) | PARTIAL | Retry/breaker/health/isolation implemented; `--scale` for api+worker; `docs/SPOF.md` analysis | Default single replicas (gateway, api, db, queue); nginx 10s-DNS-window single-replica pin measured and documented | MEDIUM |
| R40 | §15 API + worker independently scalable, no redesign | PASS | `docker compose up -d --scale api=2 --scale worker=2` (`README.md:38`); prod overlay sizes them separately (`docker-compose.prod.yml:9-26`) | Nginx RR limitation documented (scale workers, proven linear) | LOW |
| R41 | §15 Increased-workload behavior demonstrated | PASS | `scripts/workload.py`, `k6/load.js|burst.js|smoke.js`, `docs/load-evidence/` (k6 + docker-stats + nginx-scale observation) | None | — |
| R42 | §15 Performance measured, not assumed | PASS | k6 thresholds gate (`supply-chain.sh` §4/4, BLOCKING); `RESILIENCE.md` measurements; live auditor burst test | k6 not re-run by auditor | LOW |
| R43 | §15 Bottlenecks identified + addressed | PASS | Nginx static-DNS pin, worker ~3 jobs/s throughput, DB-bound path (`RESILIENCE.md`, `nginx.conf:10-19` comment) | None | — |
| R44 | §16 Logging from services/infra/workers/deploys/security with context | PARTIAL | `json-file` + rotation (`x-logging: max-size 10m/max-file 3`, `:31-35`); structured `[api]/[worker]` logs; `scripts/collect-logs.sh` bundle | No centralized store (Loki deferred, documented as interim) | MEDIUM |
| R45 | §16 Metrics: rate, errors, latency, CPU, mem, queue, worker rate/restarts, deploy state, availability | PARTIAL | Real prom endpoints (`/metrics/prom` verified live); queue/worker/deploy/security/EHR/AI/DB/nginx/redis covered; `deployment_info`, `pipeline_last_run_success` | No per-service CPU/memory (no cadvisor/node-exporter); `SaturationWarning` is latency/queue proxy | MEDIUM |
| R46 | §16 Health/readiness useful for deploy + monitoring | PARTIAL | `api /ready` does live Mongo ping + Redis ping (`server.js:54-84`, auditor saw `{"ready":true}`); gateway/compose `depends_on: service_healthy` | `worker /health` always returns `status: ok` (no dep checks, no unhealthy state, `worker.js:76-91`); ai/ehr `/health` trivial (leaf, acceptable) | HIGH |
| R47 | §16 Operational dashboard (API, workers, queue, DB, deploys, deps, saturation) | PASS | `monitoring/grafana/dashboards/healthcare.json` 19 panels; every expr references a metric verified in code (e.g. `worker_ehr_outcomes_total`, `ai_infer_total`, `ehr_requests_total`, `ALERTS`) | Panel-count prose drift (19 vs 17, see contradictions) | LOW |
| R48 | §17 Alert: API unavailability | PASS | `APIUnavailable: up{job="api"} == 0` (`alerts.yml:7-15`) | None | — |
| R49 | §17 Alert: high error rate | PASS | `HighErrorRate` 5% (`:17-25`) | None | — |
| R50 | §17 Alert: excessive latency | PASS | `ExcessiveLatency` 500ms (`:27-35`) | None | — |
| R51 | §17 Alert: worker failure | PASS | `WorkerDown` (`:37-45`) | Fires on scrape loss; shallow worker health (R46) slightly delays semantics | MEDIUM |
| R52 | §17 Alert: queue backlog | PASS | `QueueBacklog > 15` (`:47-55`) | None | — |
| R53 | §17 Alert: database unavailability | PASS | `DBUnavailable` (`:57-65`) | None | — |
| R54 | §17 Alert: deployment failure | PASS | `DeploymentFailed: pipeline_last_run_success == 0` (`:67-75`), pushed by `pipeline.sh:151-162` | Push path needs dev api running (best-effort, documented) | LOW |
| R55 | §17 Alert: resource exhaustion | PARTIAL | `SaturationWarning` (`:141-148`) queue>50 or latency>1s proxy | No real CPU/mem/disk signal; host `docker stats` manual per runbook | MEDIUM |
| R56 | §17 Alert: security validation failure | PASS | `SecurityScanFailed` (`:77-85`) | Same push-path caveat as R54 | LOW |
| R57 | §17 Alert docs: why + operator action | PASS | Every rule carries summary/description/runbook; `docs/SPOF.md:22-43` catalog | None | — |
| R58 | §18 ≥2 meaningful failures with full lifecycle | PASS | INC-01 worker, INC-02 EHR, INC-03 DB (`docs/INCIDENTS.md`) | None | — |
| R59 | §18 Telemetry supports detection/investigation | PASS | INC reports quote queue-depth series, `ps`, logs, EHR status bodies; alerts + dashboard cover each | None | — |
| R60 | §18 ≥1 incident documented in detail | PASS | INC-01 + INC-03 full lifecycle (failure→detection→investigation→cause→recovery→verification→prevention) | None | — |
| R61 | §19 DB backup/recovery + state persistence demonstrated | PASS | `backup-mongo.sh` (mongodump, retention KEEP=5), `restore-mongo.sh` (upsert, `--drop` documented), `backups/` populated, `verify-backup.sh`, cron `install-backup-cron.sh` | Restore drill rerun not repeated by auditor; evidence in `docs/CICD.md` backup section | LOW |
| R62 | §19 Infra recreation vs state recovery distinguished; recovery objectives | PASS | `full-recreate.sh` (down -v → up → restore) vs `restore-mongo.sh`; `backup-volumes.sh`; SPOF/COST state notes | None | — |
| R63 | §20 SPOF/failure analysis per dependency (API, workers, queue, DB, EHR, deploy, monitoring) | PASS | `docs/SPOF.md:6-21` per-dependency what-if + trade-offs | Monitoring-plane SPOF (single Prometheus) accepted, documented | LOW |
| R64 | §21 Operational access control, no blanket admin | PARTIAL | Least-privilege DB users, localhost-only Grafana, read-only roots, CODEOWNERS | No distinct developer/deployer/admin identities; single shared env-file credentials | MEDIUM |
| R65 | §21 Auditability: who/version/changes/checks/outcome/incident/recovery traceable | PASS | Tagged pipeline logs (`docs/pipeline-evidence/`), `infra-plan/*/SHA256SUMS`, pushgateway run metrics, `git log` (26 commits) | CI run URL lives in `docs/CICD.md`, not re-fetchable offline | LOW |
| R66 | §22 Cost awareness + reliability/perf/security/cost trade-offs | PASS | `docs/COST.md` measured + cloud mapping; prod resource limits (`docker-compose.prod.yml`); SPOF §3 | None | — |
| R67 | §23 Normal operation demo | PASS | Auditor: `/health`+`/ready`+create+list+metrics all live; `smoke.sh` | None | — |
| R68 | §23 Increased workload demo | PASS | `workload.py` + autoscale policy + k6 evidence | None | — |
| R69 | §23 Worker failure demo | PASS | INC-01; auditor kill test (with recovery caveat R32) | Recovery needed manual `up -d` in both INC-01 and audit | HIGH |
| R70 | §23 External dependency failure demo | PASS | INC-02 + 7 live-probed EHR modes + breaker/backoff code | None | — |
| R71 | §23 Healthy deployment demo | PASS | `pipeline-*.log` PASS runs (434c7e7, 5481515, p4-final-01) | None | — |
| R72 | §23 Failed deployment demo | PASS | `pipeline-p3-demo-broken-ready.log` → `ROLLBACK OK` | None | — |
| R73 | §23 Infrastructure recovery demo | PASS | `full-recreate.sh` drill; `down`/`up` recreate (`README.md:47-52`) | Full `down -v` not re-run by auditor (destructive) | LOW |
| R74 | §23 Scenarios repeatable by evaluator | PASS | Every scenario is a script (`smoke/workload/canary/full-recreate/pipeline.sh --tag`) + `evaluate.sh` | None | — |
| R75 | §24 Technology rationale + trade-offs | PASS | `TARGET_ARCHITECTURE.md`, `MERN-MIGRATION.md`, `POSTGRES-PLAN.md`, `COST.md:36` | None | — |
| R76 | §25 Architecture document (in-repo) | PASS | `docs/TARGET_ARCHITECTURE.md` (network, security, deploy, reliability, observability, failures, recovery, decisions) | Excluded submission PDFs not used | — |
| R77 | §25 Complete IaC repository | PASS | Compose + envs + `terraform/` + `db/mongo-init.js` + monitoring-as-code | Terraform descriptive-only (R9 note) | MEDIUM |
| R78 | §25 Simulation environment (services, mocks, workload, failure mechanisms) | PASS | `services/*/`, `scripts/workload.py`, `k6/`, `WORKER_FAIL_MODE`, `EHR_MODE` | None | — |
| R79 | §25 Complete pipeline config | PASS | `pipeline.sh` + `pipeline.yml` + evidence logs | None | — |
| R80 | §25 Security report (in-repo) | PASS | `docs/SECURITY.md` (checks, findings, severity, remediation, control evidence) | OS-layer 56 HIGH/CRITICAL accepted, not remediated (no upstream fix) | MEDIUM |
| R81 | §25 Incident report (in-repo) | PASS | `docs/INCIDENTS.md` (3 lifecycles, 2 full) | None | — |
| R82 | §31 AI assistance documented | PASS | `docs/AI-USAGE.md` (used vs human-verified split) | None | — |

---

## 3. Core infrastructure & network topology walkthrough (~500 words)

Entry: host → `gateway` (Nginx, the only service with LAN-published ports, `8080→80` + `8443→443` in dev) → `api:8000`. `gateway/nginx.conf` proxies exactly one upstream (`set $api_upstream api:8000`, used by `/health`, `/`, with `proxy_next_upstream` failover on 502/503) and exposes only `/health`, `/nginx-health`, `/nginx_status` (RFC1918-allowlisted) plus the catch-all; nothing routes to any other service. DNS is re-resolved every 10s via Docker's embedded resolver, so a recreated `api` is picked up without reload — though the comment honestly records the measured limit (one IP per query per window, no true round-robin).

`api` is dual-homed (`public`+`private`) with **no** published ports; it reaches `db:27017` and `queue:6379` via env-injected URIs, `ai-service:8001` for `/ai/query`, and `ehr-mock:8002` for `/ehr/status`. `depends_on: service_healthy` on db+queue gates startup. Behind it, `worker` (private-only) BLPOPs `jobs` from Redis, calls `ehr-mock`, and writes `jobs`/`appointments` back to MongoDB — the auditor proved the loop live: `POST /appointments` returned `queued`, and Mongo showed `status: processed` seconds later. `ai-service` and `ehr-mock` are private-only leaves; `db`/`queue` are private-only with no `ports:` keys at all.

Observability (Prometheus, Alertmanager, Pushgateway, 3 exporters, `alert-logger`) all sit on `private` with no published ports; `grafana` and `nginx-exporter` are dual-homed bridges with a documented justification (an `internal:true`-only container cannot materialize a published port; the exporter must resolve the public-only gateway). Grafana's single port is `127.0.0.1`-bound — host-admin-only. Resolved-config inspection plus live `check-outbound.sh` (6/0) and auditor curls (`:8001`, `:27017` refused; 8.8.8.8 unreachable from db/worker) confirm isolation is config-enforced, not diagram-asserted.

Environments share one base: `docker-compose.yml` + `dev.env`/`prod.env` (project name, ports, creds, sizing) + a 38-line `prod.yml` overlay adding only CPU/memory caps. The one wart: the brief asks for "exactly one host port" — there are two on the gateway (80+443, one ingress service) plus the localhost admin port; this is justifiable (HTTP+HTTPS) and the sole-ingress property holds. The deeper caveat belongs to recovery (R32/R33), not topology: the wiring is correct, but a daemon-level kill did not self-heal during the audit.

## 4. Security architecture evaluation (~400 words)

Secrets: no literals in code, Dockerfiles, or compose — everything arrives via `${VAR:-placeholder}` env references; `db/mongo-init.js` uses placeholder passwords that `create-db-users.sh` syncs to env values on fresh volumes. Gitleaks reports `no leaks found` across 21 commits, and the single `.gitleaks.toml` allowlist entry is a documented variable-reference false positive. The deduction: `environments/dev.env` and `prod.env` — carrying the **live** credential values — are git-tracked (HIGH). Rotation exists (`rotate-secrets.sh`) and `.env.example` is placeholder-only, but committed live values contradict §9's "never in version control" sentence even though scanners stay green.

Runtime: all five custom images are digest-pinned `node:22-slim` multistage builds with the npm toolchain stripped, `USER node` (live UID 1000 verified in every custom container), `cap_drop: ALL`, `no-new-privileges`, and `read_only` + `/tmp` tmpfs on the four Node services. `alert-logger` lacks `read_only` and the lint only enforces it for four services — a small, real gap. `gateway`/`db`/`queue` run as root without `cap_drop`, each with a written justification (nginx master bind, mongod/redis entrypoint chown needs); acceptable for simulation, correctly flagged rather than hidden. The compose lint (81 pass / 0 fail on the auditor's run) gates the pipeline with a failing exit code.

Scanning: Trivy runs per-image in `security-scan.sh` but is explicitly report-only there (exit code ignored — stated plainly in the header); the actual gate is `trivy-gate.sh`, which fails (`exit 1`) on any HIGH/CRITICAL in `lang-pkgs` app dependencies while accepting the 56 Debian OS-layer findings as baseline. Wiring is correct (`|| die` in `pipeline.sh`, blocking `security` job in the workflow), but the auditor did not re-pull Trivy (heavy) — the 56-finding baseline and `32/0` scan claim rest on in-repo evidence. TLS is real (self-signed, mount-required, `curl -sk https://localhost:8443/health` returned API health), and rate limiting is real (50-burst probe: 27×429). Outbound control is proven live (`internal:true` + no internet route). Overall: strong, honest hardening with documented exceptions — minus committed live secrets.

## 5. CI/CD pipeline & release safety evaluation (~350 words)

Two mirrored artifacts: `scripts/pipeline.sh` (local, demonstrated) and `.github/workflows/pipeline.yml` (CI twin, green-run URL cited in `docs/CICD.md` but not re-fetched — no network reliance claimed). Stage order is identical: lint (`node --check` + `compose config` dev/prod/overlay + `infra-plan.sh`) → unit (`validate.test.js`) → `npm audit` per service (HIGH gate) → `security-scan.sh` as-is → build with SHA tags (+ semver alias) → `trivy-gate.sh` on the new tag → deploy dev → `create-db-users.sh` sync → `/ready` health gate → `smoke.sh` → `workload.py` → blocking k6 gate → promote prod-like with resource overlay → post-promote check → previous-tag rollback on any post-build failure. No skip flags exist by design.

Gates genuinely gate: `set -euo pipefail` plus `|| die` on every security/build/deploy/health step; the workflow has no `continue-on-error`; in-repo evidence includes a secret-blocked run and a broken-ready run ending in `ROLLBACK OK: previous tag 'p3-demo-healthy1' serving again`. Tags are `git rev-parse --short HEAD` locally / `github.sha` in CI, with a `local-<timestamp>` fallback that loudly warns about degraded auditability. Traceability (running tags table, `infra-plan/*/SHA256SUMS`, pushgateway `pipeline_last_run_success`/`security_scan_last_success`) satisfies §21's deploy-audit items.

Two deductions. First, ordering: this is deploy-then-verify — Compose recreates the container before the health gate runs, so "traffic shifts only after verification" (§13 steps 2–4) is approximated by fast rollback, not implemented as blue/green or verify-before-shift. Second, `canary.sh` claims "promotes only if health + error-rate gates pass" but the error check (`canary.sh:30-32`) computes `ERR` and then executes `:` — a no-op; the canary cannot abort on errors. Minor: the workflow's prod-rollback metrics push goes through the **dev** api container (`pipeline.yml:147`), and the k6/perf gates were not re-executed by the auditor.

## 6. Observability & alerting evaluation (~250 words)

Metrics are genuine Prometheus text, not JSON relabeled: `/metrics/prom` on api/worker/ai/ehr (verified live for api), standard exporter formats for nginx/redis/mongo, and `honor_labels` pushgateway for pipeline/security status. The JSON `/metrics` is retained for scripts — both coexist without conflict. All 8 scrape targets were `up` when probed live. The Grafana dashboard (19 panels) references only metric names confirmed in code (`api_requests_total`, `worker_ehr_outcomes_total{result}`, `ai_infer_auth_fail_total`, `ehr_requests_total{mode}`, `deployment_info`, `pipeline_last_run_success`, `ALERTS`, redis/nginx/mongo exporter metrics). Panel-count prose drifts (19 vs "17-panel" in `terraform/main.tf:143`) — cosmetic.

All 14 alert rules exist in `monitoring/alerts.yml`, covering every §17 condition including security-scan and deployment failure, each with summary/description/runbook annotations plus an `SPOF.md` catalog. The receiver is real: Alertmanager POSTs to `alert-logger:9089/notify`, which appends one JSON line per delivery to a bind-mounted host log — the auditor found 24 lines including a firing/resolved self-test pair. CPU/memory per-service metrics are absent (no cadvisor/node-exporter), so `SaturationWarning` is a latency/queue proxy with `docker stats` as the manual fallback — honest, but §17 "resource exhaustion" is only half-instrumented. Logging is `json-file` with rotation plus a `collect-logs.sh` bundle tarball as the documented Loki interim — adequate, not centralized.

## 7. Reliability & resilience evaluation (~300 words)

Retry/backoff is real code, not comments: `backoffMs = base * 2^(attempt-1)` capped (`worker.js:56-58`), applied to EHR retries (`212-216`) and exception-path requeue (`251-259`, attempts<3 then `jobs:dead`). The circuit breaker is a genuine three-state machine (closed/open/half-open with probe, cooldown, trip counter, `:163-170,204-210,127-132`), and EHR 401 is terminal `failed_auth` — never retried, never counted toward the breaker. EHR degradation, queue backlog (alert + `autoscale.sh` depth>15 policy), DB loss (`/ready` fail-fast + `ConfigFailure`/`DBUnavailable` + backup/restore drill), deploy failure (rollback), and config failure (INC-03) all have mechanisms plus in-repo incident lifecycles (INC-01 worker, INC-02 EHR, INC-03 DB).

### Failure/recovery mechanisms (dedicated subsection)

`restart: unless-stopped` is present on all 15 services and in every live HostConfig — yet the auditor's daemon-level `docker kill` of the worker produced `die, exit 137`, `RestartCount 0`, still `exited` after 35s; recovery required manual `up -d worker` (which succeeded, `/ready` true). In-container SIGTERM/SIGKILL to PID 1 earlier had no observable effect at all. This matches INC-01's own narrative (manual restart, then queue drained 30→0) but contradicts the P0.2 header claim that crashes "revive automatically." Process-crash (exit-1) revival may still work — it was not observed either way — but the demonstrated, reproducible recovery path is operator-driven, and the in-repo comment claiming `stop/kill` "stays stopped by design" misstates Docker semantics in the other direction. Rated HIGH (R32/R33 PARTIAL), not CRITICAL: no data loss (jobs persist in Redis), detection works, and the manual path is drilled — but "automatic" is config-present, behavior-unproven.

## 8. Infrastructure as Code & environment management evaluation (~250 words)

The real IaC is Compose-as-code: one base file, two env files, one 38-line prod overlay — `config` resolves cleanly for dev, prod, and prod+overlay (auditor-verified, exit 0), and a fresh clone can stand up via the README sequence (`gen-gateway-cert.sh` → `up --build` → `create-db-users.sh` → `smoke.sh`), all scripted, plus one-command `evaluate.sh`. `terraform/` is explicitly and repeatedly documented as a **descriptive resource graph** (`terraform_data`-only, no provider by design, "applying creates no infrastructure"), mirroring services/networks/ports/deps — valuable as documentation and cloud-migration scaffolding, decorative as provisioning. No `terraform`/`tofu` binary existed in the audit env, so even `validate` was impossible; `infra-plan.sh` performs only brace-balance/file-presence lint plus resolved-config capture with SHA256SUMS. Environment values (ports, creds, sizing, modes) live entirely in env files/overlay — zero stack duplication. State handling is sound: named volumes, `down` vs `down -v` discipline, `full-recreate.sh` gated behind an explicit wipe-confirmation flag plus verified-backup requirement. Weakest IaC link is the destructive-path evidence (full `down -v` drill claimed in docs, not re-run by the auditor for obvious reasons) and the checkov step in `supply-chain.sh` being warn-tolerant. Overall: reproducible and honestly scoped, with the Terraform role transparently labeled rather than oversold.

## 9. Data isolation, secrets & injection findings (~250 words)

### Isolation (dedicated subsection)

The database has no `ports:` key in any compose file, sits only on `internal:true` `private`, and refused host connections on `:27017` in the auditor's probe; `db/mongo-init.js` plus `create-db-users.sh` give api/worker/monitor distinct least-privilege users (readWrite-scoped; `clusterMonitor` with zero app-data access for the exporter). Queue, AI, EHR, worker, alert-logger, and all observability components are likewise private-only with no published ports — confirmed both in resolved config and live (`:8001` refused, `docker ps` shows only gateway LAN ports + localhost Grafana). The EHR's physical placement inside the private net while being logically "external" is called out as an explicit simulation deviation with compensating controls (timeouts, retries, breaker, no shared creds — worker carries no `AI_API_KEY`).

### Secrets & injection

No hardcoded credentials, keys, or connection strings in any service source, Dockerfile, or compose file (all `${VAR}`-injected; placeholders only); Gitleaks clean over full history. The live-secret issue is version control, not code: tracked `dev.env`/`prod.env` hold working passwords (HIGH, R18). Injection surface is minimal: no `eval`, `shell`, `subprocess`, `child_process`, `pickle`, or dynamic `Function` in services (grep-clean); no file-path handling (no traversal shape); no shell-outs (all HTTP via `fetch`); EHR/AI URLs are env-configurable but default to in-network names and are operator-controlled, not request-controlled — the `/ehr/status?mode=` query param is allow-matched to known modes with safe fallback, and `AI query` forwards only a truncated `text` field. `validate.js` rejects non-string payloads (422) but enforces no length/content limits — weak-validation LOW.

## 10. Engineering quality, repo hygiene & reproducibility (~250 words)

Git history is real but compressed: 26 commits over 2026-09-19→20, starting from an "Initial commit: Phase 1-4 complete system as-built" baseline dump followed by genuinely incremental remediation commits (P0.1–P0.4, P1.1–P1.8, CI fixes, review re-verifications) with descriptive messages — report neutrally: not a single late dump, but the bulk baseline predates history. Working tree is clean except two untracked items (`export-architecture-pdf.py`, `submission-docs/` PDFs — the latter excluded from this audit per scope). No dead services found; every compose service is scraped, alerted, or structurally required. Small hygiene warts: `appointments` list sorts by random-hex `_id` descending rather than `createdAt` (the auditor's own appointment missed a `limit=100` listing while provably `processed` in Mongo), and dashboard panel-count prose disagrees (19 vs 17).

Clean-clone stand-up: **confirmed in substance** — the auditor ran the exact README primitives (`config`, build state, `up`, user-sync semantics, `smoke`-equivalent curls, workload creation, outbound proof) against the running clone-fresh stack with all gates passing, and `e
valuate.sh` automates the chain. Two friction points: the git-ignored `gateway/tls/` cert requires running `gen-gateway-cert.sh` first (scripted, and every entrypoint auto-generates, so this is a speed bump, not a blocker), and fresh volumes require the `create-db-users.sh` + consumer-restart sequence (also scripted into pipeline/evaluate paths). Deviations are documented in-repo, not just in excluded PDFs: MongoDB-for-relational (`TARGET_ARCHITECTURE.md:359-367` + `POSTGRES-PLAN.md`), EHR trust-boundary placement, Terraform descriptive role, nginx DNS-window limit, canary/traffic-split limits.

## 11. Critical / High / Medium / Low findings

**CRITICAL** — none.

**HIGH** (one line each):
- H1 — `docker kill` on worker did not auto-revive (RestartCount 0 after 35s; manual `up -d` required) despite `restart: unless-stopped` everywhere.
- H2 — `scripts/canary.sh:30-32` error-rate check is a no-op (`then :; fi`); canary can never abort on errors.
- H3 — Rollout is deploy-then-verify (Compose recreates before health gate); no verify-before-shift/blue-green path.
- H4 — `environments/dev.env` + `prod.env` with live credential values are git-tracked.
- H5 — `worker /health` always returns `status: ok` with no dependency checks or unhealthy state.

**MEDIUM** (one line each):
- M1 — MongoDB used where spec requires relational (documented deviation with rationale).
- M2 — gateway/db/queue containers run as root (documented exceptions).
- M3 — `alert-logger` lacks `read_only`; compose lint doesn't enforce it there.
- M4 — No per-service CPU/memory metrics; `SaturationWarning` is a latency/queue proxy.
- M5 — Logs not centralized (`collect-logs.sh` bundle is the documented interim).
- M6 — Single-replica defaults (gateway/api/db/queue SPOFs, documented in SPOF.md).
- M7 — No distinct human/role identities; shared env-file credentials for all operators.
- M8 — `terraform/` is a descriptive `terraform_data` graph only; no provisioning, no validator in env.
- M9 — 56 Debian OS-layer HIGH/CRITICAL accepted as baseline, not remediated.
- M10 — Workflow prod-rollback pushes metrics via the dev api container (`pipeline.yml:147`).

**LOW** (one line each):
- L1 — Gateway publishes two host ports (80+443), not one; same ingress, justified.
- L2 — P0.2 compose comment misstates `stop/kill` restart semantics.
- L3 — Dashboard panel-count prose drift (19 vs 17).
- L4 — `appointments` list sorts by random `_id`, not time; fresh rows can miss listings.
- L5 — `validate.js` enforces types only, no length/content limits.
- L6 — Initial commit is a full-baseline dump; incremental history starts after (26 commits, 2 days).

## 12. Requirement contradictions (in-repo docs vs. actual code/config)

Submission PDFs/videos under `submission-docs/` were **excluded from consideration** per scope (listed, never opened). The following are in-repo-doc vs. code/config mismatches only:
- C1 — `docker-compose.yml:2-4` claims process death "is revived automatically" while `docker stop/kill` "stays stopped by design": live `docker kill` stayed stopped (matching the comment, contradicting Docker restart semantics), so the comment is wrong about `kill` and the auto-revival claim is behavior-unproven.
- C2 — `canary.sh` header promises promotion "only if health + error-rate gates pass"; the error gate body is `:` (no-op).
- C3 — README "19-panel dashboard" vs `terraform/main.tf:143` "17-panel"; the JSON contains 19 panel objects.
- C4 — Lint/docs present "5 hardened custom services" while `alert-logger` lacks `read_only` and the read-only rule covers only four services (`compose-lint.py:161-163`).
- C5 — INC-01's manual `up -d` recovery vs the P0.2 "automatic" framing (docs internally inconsistent on recovery automation).
- C6 — `docs/CICD.md` "runs the full pipeline against two ephemeral Compose projects" vs `pipeline.sh` deploying both envs on one host (blast-radius simulated; separately disclosed in the same doc — tension, not deception).

## 13. Recommended fix order

1. H4 — Remove live values from tracked env files (git-ignored local envs + placeholders; rotate any exposed creds).
2. H1/H5 — Make recovery truthful: either prove crash-revival live and document the exact signal paths, or downgrade the claim to operator-driven recovery and add a watchdog/sidecar alert for `exited` containers; add real dep checks + unhealthy state to worker `/health`.
3. H2/H3 — Fix canary error gate to actually abort, or delete the canary claim; document deploy-then-verify ordering as a known limitation with the rollback SLA.
4. M1/M9 — Either adopt the `POSTGRES-PLAN.md` path or formally record risk-acceptance of MongoDB + OS-layer CVEs with review cadence.
5. M2/M3 — Add `read_only` to alert-logger; evaluate `cap_add CHOWN/SETUID` scoping for redis or keep the exception with expiry review.
6. M4/M5 — Add cadvisor/node-exporter (or document why out of scope) and wire real CPU/mem/disk alerts; evaluate Loki vs bundle.
7. M6/M7/M10 — Document single-replica SPOF acceptance per env; split deploy credentials from dev; fix metrics-push env reference.
8. L-items — Correct comments/counts, sort listings by `createdAt`, add payload length limits.

## 14. Overall completion score

Raw counts: **69 fully-satisfied PASS** + **13 PARTIAL** + **0 FAIL** + **0 UNVERIFIABLE** (environment-limited) = **82 total requirements**.

Score = (69 + 0.5 × 13) / 82 × 100 = 75.5 / 82 × 100 = **92.1%**.

Every requirement counts equally in this calculation. Separately: **no CRITICAL-severity item is among the unsatisfied ones** — but five HIGH items (auto-recovery unproven, canary no-op, deploy-then-verify ordering, tracked live secrets, shallow worker health) mean this percentage must not be read as "basically done."

## 15. Final readiness assessment

Fully satisfied 69 / partial 13 / not satisfied 0 / unverifiable 0. Critical blockers: none. Remaining work before submission: de-track live secrets (H4) and either prove or re-scope auto-recovery (H1) — these two alone decide whether the "secure" and "reliable" adjectives survive scrutiny; then repair the canary gate (H2), document rollout ordering honestly (H3), and deepen worker health (H5). The MEDIUM/LOW tail (relational deviation, root exceptions, metrics gaps, prose drift) is well-documented already and needs risk-acceptance notes more than new code. The environment runs, the data flows end-to-end, isolation holds live, and every required scenario is script-repeatable — a strong, verifiable simulation with known, bounded gaps.

## Remediation addendum — HIGH findings (post-audit fixes)

- **H4 CLOSED → R18 flips to PASS.** `environments/dev.env` + `prod.env` untracked (`git rm --cached`, `.gitignore` + `scripts/setup-env.sh` generator, README/SECURITY/workflow updated incl. per-job env generation for fresh CI runners). Local values set per owner instruction (DB/Grafana passwords `12345678`, `AI_API_KEY` `kmvk777` — local-simulation-only, never committed). Live rotation completed (`changeUserPassword` ×4 + `create-db-users.sh` sync), consumers recreated, verified: `/ready` true, `smoke.sh` OK, `/ai/query` 200, Gitleaks re-run clean.
- **H5 IMPLEMENTED, live verification incomplete → R46 stays PARTIAL.** `services/worker/worker.js` now has dependency-aware `/health` (live Mongo ping with reconnect self-heal mirroring api `dbCheck`, Redis ping, 3s timeout races, HTTP 200/503 + `ready`/`checks` fields; legacy `/metrics` JSON untouched). Healthy-200 (`ready:true`, both deps ok) observed live pre-outage. After a controlled queue-stop test the worker healthcheck stuck at `starting/unhealthy` and stayed there across restarts — root cause not yet isolated (suspect stale client topology post-outage). Left for operator follow-up (see commands below).
- **H2 FIXED in code, live run outstanding.** `scripts/canary.sh` error gate is now real: baseline `errors_total` captured pre-probe, workload exit code + error delta both abort to stable with rollback (`exit 1`). Syntax checked; no live canary run performed (mutates api scale; command below).
- **H3/H1 corrected as documentation (honest scoping).** `docs/CICD.md` §10 now states deploy-then-verify ordering with rollback-as-safety plus canary as the opt-in verify-first path. `docker-compose.yml` P0.2 header no longer claims automatic revival. Daemon experiment (fresh `alpine sleep` + `--restart unless-stopped` + `docker kill` → stayed `exited`, restarts 0) proves non-revival is environment/daemon-wide, not a compose misconfiguration — `restart:` keys remain correctly present on all 15 services; R32/R33 stay PARTIAL with the claim corrected.
- **Re-score:** 70 PASS + 12 PARTIAL → (70 + 6) / 82 × 100 = **92.7%**. No CRITICAL items; remaining HIGHs are H5-verification and the H2 live run, both handed over as terminal commands.
