# EXECUTABLE BUILD PROMPT — Paste this into OpenCode (or any agentic coding model) to finish the project

**Updated 2026-09-19** to reflect actual progress: **Phase 0 (Node.js/Express migration) and Phase 2 (hardening + security validation) are DONE.** This revision removes them from the active task list, folds their real outcomes in as constraints the agent must respect (so Phase 3/4 work doesn't contradict or redo them), and starts the agent at **Phase 3**.

**How to use this file:** Paste the entire contents below (from `## SYSTEM ROLE` to the end) as a single prompt to your coding agent. It assumes the repo already contains `docs/TARGET_ARCHITECTURE.md`, `docs/PHASES.md`, `docs/SECURITY.md`, and `docs/MERN-MIGRATION.md` — tell the agent to read all four before writing any code.

---

## SYSTEM ROLE

You are a senior DevSecOps/infrastructure engineer implementation agent working inside an existing repository. Read `docs/TARGET_ARCHITECTURE.md`, `docs/PHASES.md`, `docs/SECURITY.md`, and `docs/MERN-MIGRATION.md` in full before writing any code — they are the architectural and historical source of truth. Do not deviate from the architecture they describe, and do not re-do or contradict work already completed in Phase 0/Phase 2 (see "ALREADY DONE" below).

**Non-negotiable constraints (apply to every remaining phase):**
- Stack is fixed and already running: **Node.js 22** + Express, MongoDB 7, Redis 7, Docker + Docker Compose, Nginx, Ubuntu/Mint, Terraform (documentation/parameterization role only), GitHub Actions (or `pipeline.sh` fallback), Prometheus, Grafana, Trivy 0.74.0, Gitleaks 8.30.1, k6.
- Free/open-source/free-tier only. No paid services. No real cloud deployment.
- No frontend of any kind. No real AI agent. No real EHR integration. No real patient data. No telephony. Permanently out of scope per spec §26 — never add them.
- MongoDB is a **documented, intentional, twice-reaffirmed deviation** from the PDF's relational-database requirement (Phase 1 decision, reaffirmed at the MERN migration — see `docs/SECURITY.md` §1). **Do not migrate to Postgres.** If relational semantics are ever mandated later, that is a standalone future phase with its own backup/restore proof, not something to fold into Phase 3/4.
- Only the Nginx gateway ever gets a published host port. MongoDB, Redis, the AI service, the worker, and the EHR mock must never be directly reachable from outside the Docker private network — this is already verified (`compose-lint.py`, 42/0/3-warn) but re-check it after any change you make.
- Keep exactly **one** primary architecture diagram (`docs/TARGET_ARCHITECTURE.md` §2). Update it in place if a real topology change is required; do not create parallel diagrams.
- A phase without its required documentation artifact is not complete, even if the code works.

---

## ALREADY DONE — do not redo, do not contradict

### Phase 0 — Node.js/Express migration (folded into Phase 2, completed 2026-09-19)
- All four custom services (`api`, `ai-service`, `worker`, `ehr-mock`) are ported from FastAPI/Python to **Node 22 + Express 4.22.3**, using the `mongodb` driver 6.21.0 and `ioredis` 5.11.1. `worker.js` uses a bare `http` health server (same contract as the old `worker.py`).
- MongoDB collections/document shapes are **unchanged** — no data migration was needed; Phase 1's persistence evidence (originally 70 appointments across `down/up`) still holds.
- Compose topology, networks, volumes, env var names, and the gateway config are unchanged from Phase 1.
- **One intentional behavior change you must preserve:** the EHR mock's `slow` mode sleeps **2s**, not 3s. (Node's precise timers made a 3000ms sleep race a 3000ms client timeout and always lose, turning `slow` into `timeout` and breaking the Phase 1 `slow`→200 contract. 2s keeps `slow-but-ok` inside the deadline.) Do not "fix" this back to 3s.
- The EHR mock already implements **all required response modes**: `ok`, `slow` (2s, 200), `error` (500, retryable), `timeout` (504), `401` (non-retryable auth failure), `unavailable` (503) — i.e., this satisfies the PDF §3 requirement in full; no further mode work is needed.
- Full before/after test evidence exists in `docs/MERN-MIGRATION.md` (smoke, workload-20, AI 200/401, EHR all modes, isolation, scale, worker-failure/recovery, persistence, prod-like) — treat this as the regression baseline for anything you touch in Phase 3/4.
- Full detail and rationale: `docs/MERN-MIGRATION.md`.

### Phase 2 — Hardening + Security Validation (completed 2026-09-19, Node stack)
- One-command gate `bash scripts/security-scan.sh` → **PASS, 26 passed / 0 failed**. This must stay green; any Phase 3 pipeline work should call this same script rather than re-implementing scan logic.
- Non-root confirmed on all 4 custom services (`USER node`); `cap_drop: [ALL]` + `security_opt: no-new-privileges:true` applied to all 4 custom services (NOT to `db`/`redis` — both need init-time privileges; this was tested and documented as an accepted exception, see `docs/SECURITY.md` R3).
- Multi-stage `node:22-slim` builds; **npm/npx/corepack binaries removed from the runtime image** (`rm -rf` in the final stage) — this is why Trivy's npm-toolchain CVE section (originally 10 HIGH + 1 CRITICAL, all inside npm's own bundled deps, not app deps) is now **zero**. Do not reintroduce npm into runtime images.
- Trivy on app dependencies (express, mongodb, ioredis): **0 findings**. Trivy on the Debian bookworm OS layer: **52 HIGH / 4 CRITICAL, no upstream fix available** — this is an accepted, documented, mitigated risk (R1 in `docs/SECURITY.md`), not something to "fix" by changing base images without cause. If you evaluate distroless in Phase 3+, treat it as a deliberate follow-up, not a blocking requirement.
- Gitleaks: clean, no leaks found. `.env` files contain placeholder/non-production values only.
- `compose-lint.py` (42 assertions): 42 pass / 0 fail / 3 documented warnings (gateway runs as root — upstream nginx design; db/queue lack `cap_drop` — tested exception; placeholder creds committed — must be replaced with real secrets before any shared/non-local use).
- Remaining risks R1–R7 are catalogued in `docs/SECURITY.md` §5. Phase 3 candidates explicitly called out there: **digest pinning** (R5) and a **Trivy `--exit-code` CI gate** (R5) — treat these as Phase 3 work items, listed again below.
- Evidence lives in `docs/security-evidence/` (current, Node stack) and `docs/security-evidence-python-stack/` (preserved pre-migration snapshot — do not delete, do not treat as current).
- `docs/PHASES.md` has already been updated to mark Phase 2 in-progress/complete with this status — update it to fully "Done" once you've closed out any Phase-2-adjacent leftover (digest pinning is Phase 3, not Phase 2, so Phase 2 itself is otherwise closed).

---

## PHASE 3 — DevSecOps Pipeline + Safe Releases  ← **START HERE**

**Goal:** A real CI/CD pipeline that reuses the existing Phase 2 security gate and can both deploy safely and demonstrably block an unsafe release.

Do:
1. Build `.github/workflows/pipeline.yml` (or `scripts/pipeline.sh` if Actions minutes are a constraint — document which was chosen and why) implementing, in order: lint → unit tests → **call `scripts/security-scan.sh` as-is** (Gitleaks + Trivy + compose-lint, already a single hard gate — do not reimplement) → build images → deploy to dev environment → health gate (poll `/ready` through the gateway until healthy or timeout, using `scripts/smoke.sh` as the baseline check) → promote to prod-like → post-promote health check → rollback to previous image tag on failure at any post-build stage.
2. **Pin base images by digest** (Node's `node:22-slim` and Nginx's `nginx:alpine`), closing out Phase 2's R5. Re-run `security-scan.sh` after pinning to confirm it still passes.
3. Add a Trivy `--exit-code 1` CI gate explicitly (Phase 2 ran Trivy as part of the local script; Phase 3 must make the *pipeline* itself fail its job/status check on a HIGH/CRITICAL app-dependency finding — the OS-layer findings in R1 are an accepted baseline and should not fail the gate, but any *new* app-dependency finding must).
4. Tag every built image with the git SHA (and optionally semver) so any running container is traceable to exact source.
5. Demonstrate a **healthy rollout**: push a good change, watch it flow through every stage to prod-like, using `scripts/smoke.sh`/`workload.py` (already proven against the Node stack) as the validation commands.
6. Demonstrate a **blocked/rolled-back release**: intentionally introduce a failure (e.g., a deliberately vulnerable *app* dependency to trip the Trivy gate you just added, or a health-check-breaking bug) and show the pipeline halting before prod-like is touched, with the previous healthy version still serving.
7. Record both demonstrations (commands + output) in `docs/CICD.md`.

**Acceptance criteria:** a security failure visibly blocks deployment (evidence log/output captured); an unhealthy deploy preserves the previously running healthy version; both are documented with reproducible steps; `security-scan.sh` still passes 26/0 (or better, if digest pinning changes the count) after pipeline integration.

---

## PHASE 4 — Observability, Scaling, Resilience, Operations

**Goal:** Make system state visible, prove scaling/load behavior with real measurements, and run full incident lifecycles.

Do:
1. Stand up Prometheus scraping: API `/metrics`, worker metrics, Nginx stub_status, a Redis exporter (queue depth, ops/sec), a MongoDB exporter. Keep Prometheus/Grafana on the internal network with admin-only access (not the public gateway route) — consistent with the private-network posture already proven in `compose-lint.py`.
2. Build Grafana dashboard(s) showing: API health/error rate/latency, worker health/processing rate, queue depth, DB health, EHR call outcome mix across **all 6 modes already implemented** (ok/slow/error/timeout/401/unavailable), deployment version/health.
3. Define Alertmanager rules for: API unavailable, high error rate, excessive latency, worker failure, queue backlog above threshold, DB unavailable, deployment failure, security-scan failure (tie this one to the Phase 3 gate). Document, for each, what it means and what an operator should do when it fires.
4. Write and run k6 scripts for normal load and increased load; use the existing `workload.py` results (avg ~16ms / p95 ~22ms on the Node stack, 19→0 drain) as the baseline to compare against, not to reproduce from scratch. Capture latency, throughput, queue-drain time, and resource usage; document bottlenecks found (e.g., Nginx static-upstream DNS behavior under `--scale`, already flagged in `docs/TARGET_ARCHITECTURE.md` §14) and how the architecture would address them.
5. Run and document **two** intentional incidents end-to-end (Failure → Detection → Investigation → Root Cause → Recovery → Verification → Prevention). Pick two of: worker failure, EHR outage, DB connectivity loss, failed deployment. Worker-failure and EHR-outage behavior is already proven functionally (backlog 5 → drain to 0; all 6 EHR modes correct) — Phase 4's job is to wrap that proven behavior in full incident-lifecycle documentation with telemetry evidence, not to re-prove the mechanics from scratch. At least one incident gets a **fully detailed** report in `docs/INCIDENTS.md`.
6. Implement and drill a MongoDB backup/restore procedure (`scripts/backup-mongo.sh`, `scripts/restore-mongo.sh`); demonstrate data loss and recovery. Note for the report: current persisted record count baseline is 70 appointments (from the last documented `down/up` cycle) — use a fresh count at drill time.
7. Write a single-point-of-failure (SPOF) analysis covering API, worker, queue, database, EHR, deployment system, and monitoring — reuse the risk framing already established in `docs/SECURITY.md` §5 (R1–R7) rather than starting a parallel risk taxonomy.
8. Write `docs/DEMO.md`: a walkthrough script an evaluator can follow start-to-finish (normal operation → architecture/network boundaries → IaC recreation → CI/CD + security gate → healthy deploy → induced failure + detection + recovery → broken deploy blocked/rolled back → trade-offs summary, including the MongoDB deviation and the EHR `slow`=2s timing decision).

**Acceptance criteria:** dashboard genuinely shows API/worker/queue/DB/EHR/deployment health; both incidents are reproducible by someone following your docs; backup/restore drill has before/after evidence; `docs/DEMO.md` lets an evaluator run the entire story unassisted.

---

## FINAL CHECKLIST — verify against the PDF before declaring done

- [x] Single public entry point; everything else private (verified, `compose-lint.py` 42/0)
- [x] Relational-DB deviation documented, not hidden (twice — Phase 1 and MERN migration; `docs/SECURITY.md` §1)
- [x] All response modes on the EHR mock implemented (ok/slow/timeout/error/401/unavailable)
- [x] Worker demonstrates retry, backoff, and recovery after failure (stop → backlog 5 → restart → drained to 0)
- [x] Non-root containers, minimal images, Trivy scanning wired into a local gate (`security-scan.sh`)
- [x] No hard-coded secrets anywhere (Gitleaks clean)
- [x] At least one real security finding fixed with before/after evidence (F1–F5 in `docs/SECURITY.md`)
- [ ] IaC reproducible/destroyable/recreatable — largely proven via Compose; confirm Terraform docs still match reality after any Phase 3/4 changes
- [ ] Two environments share base definitions, differ only in overrides/secrets — carried from Phase 1, re-verify unaffected
- [ ] CI/CD: lint, test, secret scan, build, vuln scan gate, deploy, health gate, promote, rollback — all present and demonstrated ← **Phase 3**
- [ ] At least one real security failure shown blocking a *pipeline* release (distinct from the local scan gate) ← **Phase 3**
- [ ] Zero-downtime-style promotion demonstrated ← **Phase 3**
- [ ] Failed-deployment case demonstrated (old version preserved, rollout stopped/rolled back) ← **Phase 3**
- [ ] Logs, metrics, health checks, dashboard, and actionable alerts all present ← **Phase 4**
- [ ] Two incidents run end to end; at least one fully documented ← **Phase 4**
- [ ] Backup/recovery of persistent state documented and drilled ← **Phase 4**
- [ ] SPOF analysis covers API, worker, queue, DB, EHR, deployment system, monitoring ← **Phase 4**
- [ ] Operational access/auditability: who deployed what, which checks ran, when incidents occurred, what recovery happened — all traceable ← **Phase 3/4**
- [ ] Cost-awareness discussion present ← **Phase 4**
- [x] Increased workload, worker failure, external dependency failure scenarios reproducible (Node stack, documented in `docs/MERN-MIGRATION.md`)
- [ ] Deployment, failed deployment, infrastructure recovery scenarios reproducible ← **Phase 3/4**
- [x] Exactly one primary architecture diagram, kept current
- [x] No frontend, no real AI, no real EHR, no real patient data, no real cloud deployment anywhere in the repo
- [ ] Every major PDF requirement has a row in the traceability matrix (`docs/TARGET_ARCHITECTURE.md` §17), updated to reflect Phase 0/2 completion, and Phase 3/4 rows either done or explicitly flagged as a stated limitation

When every box is checked, stop and produce a final summary of what was built, what deviates from the PDF and why (relational DB being the headline item, EHR `slow` timing being the minor one), and what would need to change to move this toward a real cloud deployment.
