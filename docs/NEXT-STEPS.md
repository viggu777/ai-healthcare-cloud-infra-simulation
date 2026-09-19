# Architecture Review & Next Steps (2026-09-19)

Review of `docs/TARGET_ARCHITECTURE.md` against the repository and both live
stacks (dev + prod-like, 14 services each, all healthy at review time).
Method: every factual claim in §§1–18 checked against `docker-compose.yml`,
`gateway/nginx.conf`, service sources, `environments/*.env`, scripts, and live
`curl`/Prometheus probes. Findings below; fixes are scoped as work items in §5,
not applied here.

## 1. Verdict

The **implemented system is sound and its evidence is real**: sole-gateway
ingress, private internal network, digest-pinned images, passing security gates
(26/0), proven pipeline rollbacks, working Prometheus/Grafana/alerting,
measured load numbers, two incident lifecycles, a drilled backup. The weakness
is the **document, not the system**: `docs/TARGET_ARCHITECTURE.md` still
contains ~25 aspirational statements presented as implemented fact (mostly
carried over from the pre-implementation draft), plus dead references to
`docs/PHASES.md`, which no longer exists. Anyone operating strictly from the
doc will expect TLS, rate limiting, restart policies, resource limits, a `/api/*`
route map, and a git history — **none of which exist**. §2 lists each item with
its correction direction (implement vs. reword).

Scorecard against the execution brief's final checklist (§3): **24 of 27 boxes
genuinely checked, 3 explicitly flagged as limitations** (Terraform maturity,
real paging receiver, CI twin unexecuted). No box is falsely checked.

## 2. Drift register (claim → reality)

Severity: **H** = doc promises behavior the system lacks (fix or reword);
**M** = misleading wording; **L** = cosmetic/stale.

| # | Location | Claim | Reality | Sev | Direction |
|---|---|---|---|---|---|
| 1 | §1 + §12 + §17 + §18.3 | Terraform in stack / `terraform/` exists / "Terraform is used" | No `terraform/` directory exists at all | H | Implement minimal `terraform/` (variables + resource-graph doc, P1-§5.12) or reword to future work |
| 2 | §2 diagram, §4, §17 | "Only gateway attached" to `public`; gateway "sole bridge" | `api`, `grafana`, `nginx-exporter` are also on `public` (required: internal-net containers can't publish ports / resolve gateway) | H | Reword: gateway is sole *published* port; api/grafana/nginx-exporter are documented dual-homed bridges |
| 3 | §3 Gateway | "Attached to both public and internal" | Gateway is `public`-only in compose | M | Reword (public-only is the *better* posture; doc has it backwards) |
| 4 | §1/§3/§4/§5 | TLS termination, HTTPS, rate limiting | `nginx.conf`: port 80 only, no `ssl`, no `limit_req` | H | Implement (self-signed cert + `limit_req`, small) or reword to future |
| 5 | §3 Gateway, §4 | `/nginx-health`, "`/api/*`, `/health`, `/ready`, `/metrics` route map" | Only `/health`, `/nginx_status`, catch-all `/` → api | M | Reword to actual routes |
| 6 | §3 API | "Internal network only" | api is dual-net (`public`+`private`) | M | Reword (unpublished port is the real guarantee) |
| 7 | §3 API | "`/metrics` (Prometheus format)" | `/metrics` is JSON; Prometheus format is `/metrics/prom` | M | Reword |
| 8 | §3 API/Worker, §5.4 | Worker calls AI service; AI failures "counted as a metric" | `worker.js` has no AI call; no AI-failure counter exists | M | Reword (drop worker→AI; keep api→AI `/ai/query`) |
| 9 | §3 Worker, §5.5, §9, §17 | Retry **with backoff**, **circuit-breaker**, `failed_auth` status | Requeue is immediate (no backoff delay); no circuit breaker; degraded status is `processed_ehr_degraded` | H | Implement (bounded backoff + breaker + `failed_auth`, P1) or reword |
| 10 | §3 Redis, §3 Worker | Worker `/health` "reports degraded" | Always returns `status: ok` | L | Reword |
| 11 | §3 API, §5 | `/ready` returns **503** when deps down | Returns HTTP 200 with `{ready:false}` (verified live) | L | Reword (or make it a real 503 — one line, changes smoke/gate parsing, so reword is safer) |
| 12 | §5.2 | Create returns **202 Accepted** | Returns 200 (`res.json()` default) | L | Reword |
| 13 | §3 Prom/Grafana | "Own container healthchecks" | Monitoring services have **no** healthchecks in compose | M | Implement (add healthchecks — easy, real value) or reword |
| 14 | §9, INC-01 | "`restart: on-failure` brings the worker back" | **No `restart:` policy on any service** (verified: zero matches) — crashed containers stay down | H | Implement (`restart: unless-stopped`, one-line, P0) |
| 15 | §6 | "`npm audit` integrated as lint/test-stage check" | Pipeline lint is `node --check` + compose config only | M | Implement (`npm audit --omit=dev` per service) or reword to Trivy-only |
| 16 | §6, §11, §14 | "Resource limits", "Defined CPU/memory limits" in prod-like | No `deploy.resources`/limits anywhere; env files have no such keys | M | Implement (prod-like limits, easy, demonstrates cost dial) or reword |
| 17 | §3 AI (implied), §6, §12, §17 | "`.env` files (git-ignored)", "`.env.*` not committed", "Git history / Git commit SHA" | **No `.git` exists**; `environments/*.env` *are* committed (placeholder values, accepted R4) | H | `git init` + initial commit (P0 — auditability claims are void without it); reword `.env` row to committed-placeholders |
| 18 | §8 table | "`prom-client` in API/worker" | Hand-rolled exposition text; no prom-client dependency | L | Reword |
| 19 | §8 table | Queue depth "Redis exporter" | Depth comes from `api_queue_depth`; exporter gives ops/sec | L | Reword |
| 20 | §8 table | Alerts → "console/log/webhook" notification | Receiver is a discard webhook; nothing notifies anyone | M | Reword (or implement local mail/webhook logger, P1) |
| 21 | §8 table, §15 | "Optional Loki (Phase 4, optional per PHASES.md)" | No Loki; `PHASES.md` doesn't exist | L | Reword (drop Loki or mark future) |
| 22 | §11 table | "`docker-compose.{dev,prod}.yml`", "`.env.dev`/`.env.prod`", "2+ replicas" defaults | None of those files exist; actual `environments/dev.env`/`prod.env`; 1 replica each | M | Reword to actual paths |
| 23 | §12 table | "`terraform/` … Yes", "`nginx/*.conf`", "`.env.*.example` committed instead" | No terraform dir; actual `gateway/nginx.conf`; actual `.env.example` + committed `environments/*.env` | M | Fix paths; terraform per #1 |
| 24 | §5/§15/§18, line 5 | References to `docs/PHASES.md` (acceptance criteria, out-of-scope note) | File deleted during docs consolidation | M | Repoint to `docs/TARGET_ARCHITECTURE.md` §15 + `docs/SPOF.md` |
| 25 | §16 tree | `src/` layouts, `nginx/`, `terraform/`, `docker-compose.dev.yml` | Aspirational layout; the "actual paths" note below it is accurate | L | Keep note, mark tree as target-shape (or collapse tree to reality) |
| 26 | §17 | "BullMQ/consumer pattern" | Custom `blpop` loop, no BullMQ | L | Reword |
| 27 | §17 | "At least one finding must be remediated" / "Audit step required" | Done (F1–F5, 26/0) — stale imperative mood | L | Reword to past tense with evidence links |

## 3. Final-checklist status (execution brief)

Checked (evidence in parentheses): single ingress (lint 70/0/4-warn); private
internals; relational deviation documented ×3; all 7 EHR modes; worker
retry/recovery; non-root + minimal + local gate; Gitleaks clean; F1–F5 fixed;
two envs sharing base (re-verified); full CI/CD demonstrated; security block
demonstrated; healthy promotion demonstrated; failed-deploy rollback
demonstrated; logs/metrics/health/dashboard/alerts live; two incidents (INC-01
full); backup drill 1519→1419→1519; SPOF + cost + auditability docs; workload/
worker/EHR scenarios reproducible; deploy/failed-deploy/infra-recovery
reproducible; one diagram; no out-of-scope builds; traceability matrix current.

Flagged limitations (3): **(a)** Terraform maturity — Compose is the proven IaC,
no `terraform/` exists (§5.12); **(b)** Alertmanager receiver is a discard
webhook — detection proven, notification not (§5.7); **(c)** GH Actions twin
unexecuted — no remote/runner (§5.11).

## 4. What was built, what deviates, what cloud needs (brief's closing summary)

**Built:** 4-service Node.js simulation + gateway + Mongo/Redis, hardened
(non-root, capped, pinned, scanned 26/0), shipped by a gated pipeline with
proven rollback, observed by Prometheus/Grafana/9 alerts/17 panels, load-tested
(k6, ~3 jobs/s/worker linear), incident-drilled twice, backup-drilled — all
free, local, reproducible via `docs/DEMO.md`.

**Deviates from the PDF (both deliberate, documented):** (1) MongoDB instead of
relational (§13 — infrastructure role identical, engine swappable); (2) EHR
`slow` = 2 s not 3 s (Node timer boundary race — `docs/MERN-MIGRATION.md`).
Everything else in §§1–2 is doc drift to be fixed, not hidden deviation.

**Toward real cloud:** Nginx → ALB/ingress + ACM certs; Compose `--scale` →
ECS Service Auto Scaling / HPA on `api_queue_depth`; Mongo → DocumentDB/Atlas
with PITR replacing the dump scripts; Redis → ElastiCache (Multi-AZ) replacing
single-instance + AOF; env files → Secrets Manager + strict IAM (replacing
simulated least-privilege); discard webhook → PagerDuty/OpsGenie; local
retention → S3/GCS log archival + managed Prometheus; single host → multi-AZ
(removes the ultimate SPOF); digest pins + Trivy gate transfer unchanged.

## 5. Next steps (prioritized)

### P0 — repo integrity (do first; small, load-bearing)

1. **`git init` + initial commit** (S). Every auditability claim (§6, §14, §17,
   SPOF §4) assumes version control that doesn't exist; pipeline SHA tagging
   silently falls back to timestamps. Accept: `git log` shows history, Gitleaks
   can run with git mode, tags become real SHAs.
2. **Add `restart: unless-stopped`** to all 14 services (S). The doc already
   promises crash revival twice; today a crashed worker stays down until a
   human intervenes. Accept: kill -9 worker → container restarts, backlog drains.
3. **Disk triage** (S). Host at **95%** (26 GB free, worsening): prune superseded
   tags (`0.1.0`, `0.1.0-dev`, `p3-demo-healthy1` ≈ 2.7 GB), `docker image prune`,
   set backup retention (keep N latest in `backups/`), remove the un-deletable
   stale backup dir (uid-999 residue). Accept: disk < 85%, retention rule in
   `backup-mongo.sh` header.
4. **Doc-fix bundle** (M): apply the "Reword" direction for all L/M items in §2
   (#2–8, #10–13, #15–16 partial, #18–27) so the doc stops over-claiming. Each
   fix is listed verbatim-ready in §2; verify with a second pass of this review.

### P1 — robustness (real behavior gaps)

5. **Gateway hardening** (M): `limit_req` zone + self-signed TLS + `/nginx-health`
   (covers #4, #5). Accept: `curl -k https://:8443` works; 429s observed under k6 burst.
6. **Worker resilience as documented** (M): bounded backoff on requeue,
   `failed_auth` terminal status on 401, consecutive-failure circuit-breaker
   (covers #9). Accept: INC-02 rerun shows breaker engaging; 401 jobs stop retrying.
7. **Monitoring healthchecks + prod parity check** (S): healthchecks on all 7
   monitoring services; confirm prod Grafana :3001 dashboard provisioned
   (covers #13). Accept: `ps` shows healthy across both envs.
8. **Real notification path** (S–M): Alertmanager webhook to a local log/mail
   sink (covers #20, checklist limitation b). Accept: induced QueueBacklog
   produces a notification artifact.
9. **Backup scheduler** (S): cron/systemd timer for `backup-mongo.sh` → honest
   RPO (today: manual). Accept: two consecutive scheduled backups in `backups/`.
10. **Pipeline lint additions** (S): `npm audit --omit=dev` per service (covers
    #15); prod-like `deploy.resources` limits (covers #16). Accept: pipeline
    green with both stages present.
11. **Execute the GH Actions twin** on a connected clone (M): first push/PR run
    (covers checklist limitation c). Accept: green Actions run linked in CICD.md.
12. **Minimal `terraform/`** (M): variables + resource-graph documentation
    mirroring compose (covers #1, #23, checklist limitation a) — or formally
    record Terraform as dropped in favor of Compose. Accept: either exists or
    the claim is gone; no middle state.

### P2 — evolution (future phases, not owed)

13. Nginx `resolver` + variable `proxy_pass` for dynamic upstreams (measured
    60/0 skew is the justification).
14. `read_only: true` + `distroless` evaluation (R5 remainder), Redis `cap_add`
    refinement (R3 experiment).
15. Managed secret store path (Vault/SSM) design note; TLS everywhere; Loki
    decision (adopt or delete all references).
16. PostgreSQL migration playbook *if* relational semantics are ever mandated
    (standalone phase per §13 — schema, `pg`+migrations, `postgres_exporter`,
    backup/restore re-proof).
17. Multi-host / real-cloud execution of §4's mapping (ALB, ASG/HPA,
    DocumentDB/Atlas, ElastiCache, Secrets Manager, paging, archival).

## 6. How to work this list

One item at a time, each ending green: code → `security-scan.sh` 26/0 (or
better) → affected demo re-run (smoke/workload/pipeline/incident as applicable)
→ doc touch-up in the same change (never let §2 grow again). Re-run this
review's method (claim → compose/source/live probe) after P0–P1 and file the
result as `docs/REVIEW-02.md`.
