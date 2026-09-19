# Architecture Re-Review & Remediation Close-Out (2026-09-19, evening)

Re-run of the `docs/NEXT-STEPS.md` method after the full P0+P1 remediation
pass: every factual claim in `docs/TARGET_ARCHITECTURE.md` §§1–18 checked
against `docker-compose.yml`, `docker-compose.prod.yml`, `gateway/nginx.conf`,
`terraform/*.tf`, service sources, `environments/*.env`, scripts, git history,
and both live stacks (dev + prod-like, **15 services each**, all Up at review
time) via direct `curl`/Prometheus probes.

## 1. Verdict

**Zero new drift.** All 27 register items from the original review are closed:
12 by implementation (P0.1–P0.3, P1.1–P1.8) and 15 by rewording to verified
reality (P0.4), each in its own independently-verifiable commit ending green
(`security-scan.sh` 32/0, affected demo re-run, doc touch-up in the same
change). The three explicitly-flagged limitations are all closed: Terraform
maturity → `terraform/` exists and validates (P1.8); discard webhook →
`alert-logger` file sink with firing+resolved artifacts (P1.4); GH Actions
twin unexecuted → green run linked in `docs/CICD.md` (P1.7).

Two residuals are host-level, not doc drift (see §4): disk at 94% (repo-scope
triage done, retention caps regrowth — the remainder is host user data outside
this repo) and the single-host simulation boundary (unchanged, still explicit).

Scorecard: **27 of 27 original boxes closed, 0 falsely checked, 0 new drift.**

## 2. Closure register (original claim → disposition)

Severity from the original review; Disposition = what closed it.

| # | Location | Original drift | Sev | Disposition (commit / evidence) |
|---|---|---|---|---|
| 1 | §1+§12+§17+§18.3 | Terraform claimed, no `terraform/` | H | **Implemented P1.8**: `terraform/{main,variables,outputs}.tf` + `environments/{dev,prod}.tfvars` (17 resources: 2 nets + 15 services, pinned images); OpenTofu `validate` SUCCESS + `plan` renders full graph for both envs |
| 2 | §2,§4,§17 | "Only gateway attached" to public | H | **Reworded P0.4**: gateway = sole *published* port; api/grafana/nginx-exporter documented dual-homed bridges (diagram + §4 + matrix) |
| 3 | §3 Gateway | "Attached to both networks" | M | **Reworded P0.4**: gateway is public-only (tighter posture; doc had it backwards) |
| 4 | §1/§3/§4/§5 | TLS/rate limiting claimed, absent | H | **Implemented P1.1**: `:443` self-signed (gen script, git-ignored) on :8443/:8444; `limit_req` 20r/s+b20 shed as 429 (`limit_req_status`); `curl -k https` OK both envs; k6 burst 378×429, 0×5xx; normal k6 0% fail |
| 5 | §3,§4 | `/nginx-health`, `/api/*` route map | M | **Implemented P1.1** (`/nginx-health` static endpoint added) + **reworded** route map to actual (`/health`, `/nginx_status`, catch-all with limit_req) |
| 6 | §3 API | "Internal network only" | M | **Reworded P0.4**: dual-homed, unpublished port is the guarantee |
| 7 | §3 API | "`/metrics` (Prometheus format)" | M | **Reworded P0.4**: `/metrics` JSON, `/metrics/prom` text (verified live) |
| 8 | §3,§5.4 | Worker calls AI service | M | **Reworded P0.4**: worker has no AI client (grep-verified); only api→AI `POST /ai/query` |
| 9 | §3,§5.5,§9,§17 | Backoff, breaker, `failed_auth` | H | **Implemented P1.2**: 3 EHR attempts (1s/2s backoff, cap 8s), breaker opens after 5 consecutive (15s cooldown, half-open probe), 401 → terminal `failed_auth` single-attempt; verified live on `unavailable` + `auth_fail` replays (logs + `breaker_open`/`worker_circuit_breaker_state` metrics) |
| 10 | §3 Redis/Worker | `/health` "reports degraded" | L | **Reworded P0.4**: always `status: ok` (code-verified) |
| 11 | §3,§5 | `/ready` returns 503 | L | **Reworded P0.4**: HTTP 200 + `{ready:false}` (code-verified, `server.js:67`) |
| 12 | §5.2 | Create returns 202 | L | **Reworded P0.4**: HTTP 200 live-verified |
| 13 | §3 Prom/Grafana | "Own container healthchecks" | M | **Implemented P1.3**: wget healthchecks on prometheus/alertmanager/pushgateway/grafana (healthy in both envs); 3 scratch exporters honestly covered by `up{}==0` + new `ExporterDown` rule (10 rules live); prod Grafana :3001 dashboard verified (17 panels) |
| 14 | §9, INC-01 | "`restart: on-failure` revives" | H | **Implemented P0.2**: `restart: unless-stopped` on every service (15 now, incl. alert-logger); host-PID `kill -9` (true crash) → restart <1s, `RestartCount` 1, backlog auto-drained, no manual step |
| 15 | §6 | "`npm audit` integrated" | M | **Implemented P1.6**: `npm audit --omit=dev --audit-level=high` per service (5/5 clean) in pipeline.sh + GH workflow; green in log |
| 16 | §6,§11,§14 | "Resource limits" in prod-like | M | **Implemented P1.6**: `docker-compose.prod.yml` `deploy.resources` on 5 Node services, layered on prod promote/rollback; `inspect` proves 512M/0.5 CPU enforced |
| 17 | §3,§6,§12,§17 | `.env` git-ignored / git history | H | **Implemented P0.1**: `git init`, 18 commits on `main`, Gitleaks git mode ("1 commits scanned", clean); pipeline SHA-tags (`:5481515` live in both envs); `.env` rows reworded to committed-placeholders (R4) |
| 18 | §8 | "`prom-client`" | L | **Reworded P0.4**: hand-rolled exposition (grep: no such dependency) |
| 19 | §8 | Queue depth via Redis exporter | L | **Reworded P0.4**: `api_queue_depth` (alert expr confirms) |
| 20 | §8 | Alerts → notification | M | **Implemented P1.4**: Alertmanager → `alert-logger:9089` file sink (`monitoring/alert-notifications/*.log`); real WorkerDown+QueueBacklog firing AND resolved artifacts on disk; Prometheus confirms firing state |
| 21 | §8,§15 | Loki / PHASES.md | L | **Reworded P0.4**: Loki dropped (future P2); PHASES refs repointed to §15 |
| 22 | §11 | `docker-compose.{dev,prod}.yml`, 2+ replicas | M | **Reworded P0.4**: single base + `docker-compose.prod.yml` override (P1.6), `environments/*.env`, 1 replica each |
| 23 | §12 | `terraform/`, `nginx/*.conf`, `.env.*.example` | M | **Fixed P0.4+P1.8**: `gateway/nginx.conf`, `.env.example` + committed placeholders; `terraform/` now real (see #1) |
| 24 | §5/§15/§18 | `docs/PHASES.md` refs | M | **Reworded P0.4**: repointed (only a historical removal note remains) |
| 25 | §16 | Aspirational tree | L | **Reworded P0.4**: labeled target-shape, note-wins rule |
| 26 | §17 | "BullMQ/consumer pattern" | L | **Reworded P0.4** (+§3): custom BLPOP loop (grep-verified) |
| 27 | §17 | "Must be remediated / audit required" | L | **Reworded P0.4**: past tense with evidence links (F1–F5, gate 32/0) |

## 3. Checklist status (execution brief + remediation accepts)

P0: git log shows history ✓ · Gitleaks git mode ✓ · SHA-tagged pipeline images (`:5481515`) ✓ · 15/15 `restart: unless-stopped` ✓ · crash→auto-restart→drain proven ✓ · stale tags pruned + `image prune` + builder prune ✓ · retention in `backup-mongo.sh` header + verified prune ✓ · stale uid-999 dir removed ✓ · M/L reword second pass clean ✓.
P1: `curl -k https://:8443` ✓ · k6 burst 429s ✓ · breaker in logs/metrics + `failed_auth` terminal ✓ · monitoring healthy both envs + prod dashboards ✓ · notification file artifacts (firing+resolved) ✓ · two scheduled backups unattended + daily cron ✓ · pipeline green with audit+resources stages ✓ · green Actions run [35449680652](https://github.com/viggu777/ai-healthcare-cloud-infra-simulation/actions/runs/35449680652) (plus follow-ups) linked ✓ · `terraform/` validates ✓.

## 4. Residuals and nuances (not drift — documented in-repo)

1. **Disk 94%** (was 95%): ~4 GB reclaimed (8 superseded app tags, 4 stale infra tags, builder cache, stale backup dir). `<85%` is unreachable from repo scope — the bulk is host user data (`~/Documents`, other projects' running containers), explicitly out of scope. Retention (keep-5) + daily cron cap regrowth; commit `337c7d2` records this.
2. **`docker kill` vs crash**: explicit `docker stop/kill` (management action) intentionally stays stopped under `unless-stopped`; unexpected process death (host-PID `kill -9`, the OOM analogue) auto-restarts. The doc states exactly this (§5.7) — verifiers should crash the process, not the container, to see revival. This preserves the INC-01 detection window by design.
3. **Single-host boundary** unchanged (§14): container kill stands in for instance failure, stated explicitly.
4. **Gate counts**: `security-scan.sh` is 32/0 (was 26/0 with 4 services; +6 for alert-logger — `docs/SECURITY.md` §10). `compose-lint` 74/0/4 (was 70). Historical 26/0/70 references are dated, not wrong.
5. **Two twin-only CI findings** (fixed, in `docs/CICD.md` §10): trivy-gate `--tag` space-form parsing; per-job TLS cert generation (fresh runners share nothing).

## 5. Deviations carried forward (unchanged, still explicit)

1. MongoDB instead of relational (§13 — infrastructure role identical, engine swappable).
2. EHR `slow` = 2 s not 3 s (Node timer boundary race — `docs/MERN-MIGRATION.md`).

*Method note: each claim above was re-checked by reading the file or probing the live system during this pass (compose config, both `ps` outputs, curl https/http/health/ready/metrics/create-code, worker `/health`+`/metrics/prom`, Prometheus rules API (10), prod Grafana dashboard API (17 panels), alert artifact file (6 lines), crontab + scheduled backup dirs, GH run conclusions, `tofu validate`+`plan`). No P2 items started.*
