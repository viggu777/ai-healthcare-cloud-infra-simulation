# Incident Reports — Phase 4 (2026-09-19, dev environment)

Two intentional incidents run end-to-end on the live dev stack, detected through
the Phase 4 monitoring (Prometheus alerts + Grafana), recovered, and verified.
Both are reproducible by following the commands below. INC-01 is the fully
detailed report; INC-02 follows the same lifecycle in condensed form.

Prerequisites: dev stack up (`docker compose --env-file environments/dev.env up -d`),
monitoring up (same command — Prometheus/Grafana ship in the base Compose file),
queue drained (`queue_depth: 0` in `GET /metrics`).

Conventions: `D` = `docker compose --env-file environments/dev.env`,
`P` = `docker exec ai-healthcare-dev-prometheus-1 wget -qO- http://localhost:9090/api/v1/query?query=`.

---

## INC-01 — Worker failure (FULL REPORT)

### Failure (17:23:42)

Stopped the single worker while the system was serving, standing in for a
crash/OOM-kill (Compose `restart: unless-stopped` — P0.2, all services —
revives a real crash, verified via host-PID `kill -9` with <1 s restart and
automatic drain; explicit `stop` holds it down so the detection window is
observable):

```bash
D stop worker
# Container ai-healthcare-dev-worker-1  Stopped
python3 scripts/workload.py http://localhost:8080 30
# enqueued=30 avg_latency_ms=6.5 p95=8.2
# queue_depth=30 requests=1247
```

Note the API stayed fast (avg 6.5 ms): producers are decoupled from consumers —
enqueueing never blocks on processing. All 30 jobs sat in Redis, none lost.

### Detection

Polled the queue and the alert state every 30 s:

| Time | queue_depth | WorkerDown | QueueBacklog |
|---|---|---|---|
| 17:24:58 | 30 | pending | pending |
| 17:25:29 | 30 | **firing** | pending |
| 17:25:59 | 30 | firing | pending |
| 17:26:29 | 30 | firing | **firing** |
| 17:26:59 | 30 | firing | firing |

```bash
D exec ... # per-check form:
curl -fsS http://localhost:8080/metrics | python3 -c "...queue_depth..."
P 'ALERTS{alertname=~"WorkerDown|QueueBacklog"}'
```

WorkerDown fired ~1.5 min after the stop (`for: 1m` + 15 s scrape); QueueBacklog
fired ~2.5 min after (`depth > 15 for 2m`). Two independent signals — liveness
(scrape) and symptom (backlog) — agreed, which is what separates "worker down"
from "worker slow" in the next incident's contrast.

### Investigation

```bash
D ps worker --format '{{.Service}} {{.Status}}'
# (empty — stopped containers are hidden by default ps; use ps -a)
D logs worker --tail=3
# worker-1  | [worker] health on 8003
# worker-1  | [worker] up concurrency=2 fail_mode=off
# worker-1  | EHR call failed for job-a37f606d5257: ... aborted due to timeout
```

No crash trace — the process was simply gone (expected: we stopped it). Queue
frozen at exactly 30 across five consecutive polls: jobs are unacknowledged in
Redis, nothing processed, nothing dropped. The last log line (an EHR timeout on
an earlier job) is noise, correctly ignored — timeouts are routine and retried.

### Root cause

Worker process absent (simulated crash). Contributing design facts, both
pre-existing and now telemetry-backed: a single worker drains ~3 jobs/s, so any
outage accumulates backlog linearly; and before Phase 4 there was no
liveness/backlog alerting — this exact failure mode was proven recoverable in
Phase 1 but would have been *silent* until a user complained.

### Recovery (17:27:37)

```bash
D up -d worker
# Container ai-healthcare-dev-worker-1  Started
# 17:27:39 queue_depth=30
# 17:27:59 queue_depth=0
```

Backlog 30 → 0 in ~22 s with zero operator data repair: unacknowledged Redis
jobs resumed exactly where they stopped.

### Verification

- `ALERTS{WorkerDown|QueueBacklog}` → 0 active series (both resolved).
- `GATEWAY_URL=http://localhost:8080 bash scripts/smoke.sh` → `SMOKE OK`
  (`requests_total: 1248, errors_total: 0, queue_depth: 0`).

### Prevention

1. `restart: unless-stopped` on all services (P0.2 — crash revival without humans; explicit `stop` stays down for the detection window).
2. WorkerDown (liveness) + QueueBacklog (symptom) alerts now cover detection —
   this incident is the proof they fire and resolve.
3. Drain-rate headroom documented (`docs/RESILIENCE.md`): ~3 jobs/s per worker,
   linear with `--scale worker=N`; backlog alert threshold (15) buys ~5 s per
   worker of reaction time at typical arrival rates — tune per environment.

---

## INC-02 — EHR outage (CONDENSED LIFECYCLE)

### Failure (17:29:04)

Recreated the EHR mock in `unavailable` mode — the dependency is logically down
while its container stays healthy:

```bash
EHR_MODE=unavailable D up -d ehr-mock
curl "http://localhost:8080/ehr/status?mode=unavailable"
# {"ehr_status":503,"latency_ms":65,"body":{"error":"EHR unavailable","retryable":true}}
```

Key nuance (checked immediately): `GET ehr-mock:8002/health` still returns
`200 {"status":"ok","default_mode":"unavailable"}`. Container health checks
cannot see this failure — only the worker's outcome telemetry can.

### Detection

Four `workload.py 20` batches (17:29:28–17:31:03) plus 90 paced creates
(17:32–17:35) kept outage traffic flowing. Worker outcome mix moved to
`unavailable_503: 80` (vs pre-outage `ok: 31`); `EHROutage` went
pending → **firing at ~17:36** (non-ok ratio > 20% for 2 m). Exact outage
footprint from Mongo: **171 appointments** `processed_ehr_degraded`.

Side observation: batch 3 showed a transient API latency blip
(avg 21.8 ms / p95 53.6 ms vs ~8–9 ms siblings) under coincident worker-DB
write contention. Not isolated further; flagged for the load-test notes.

### Investigation

- Grafana EHR-outcome-mix panel: `unavailable_503` dominant, all other results flat.
- Worker logs: no errors — by design, EHR 5xx degrades the job, it never fails it.
- `ehr-mock` container healthy (see above) → fault is *beyond* our process
  boundary: external dependency, not internal bug. This distinction drove the
  recovery choice (fix the dependency, touch nothing else).

### Root cause

External EHR dependency outage (simulated via mock mode). Worker behavior
correct throughout: jobs completed as `processed_ehr_degraded`, zero lost, zero
poisoned retries (503 is retryable but the job-level outcome is terminal
degraded — no infinite loop).

### Recovery (17:36:22)

```bash
EHR_MODE=ok D up -d ehr-mock
curl "http://localhost:8080/ehr/status?mode=ok"
# {"ehr_status":200,...,"data":"ehr-record-ok"}
```

### Verification

- 15 fresh jobs → `worker_ehr_outcomes_total{result="ok"}` 31 → 46 (100% ok).
- `EHROutage` → RESOLVED 17:40:52 (5-minute rate window slid past the burst).
- `SMOKE OK`; queue drained; no rollback or data repair needed.

### Prevention

1. `401` (non-retryable, credential/config) vs `503`/`5xx`/`timeout`
   (retryable, dependency) are now distinct outcome labels with distinct runbooks
   (`monitoring/alerts.yml` EHROutage annotation).
2. Outcome-mix panel is permanent — the only sensor that sees logical
   dependency failure behind healthy containers.
3. Hardening built (P1.2, verified above in spirit — breaker engaged on the
   `unavailable` replay, `failed_auth` proven on the `auth_fail` replay):
   circuit-breaker opens after 5 consecutive retryable EHR failures (15 s
   cooldown, half-open probe), EHR calls retry at most 3× with 1 s/2 s
   backoff, and 401 lands in terminal `failed_auth` with no retry loop.

---

## INC-03 — Database connectivity loss (FULL LIFECYCLE, 2026-09-19)

### Failure

Killed the single MongoDB container (stands in for DB host failure,
network partition, or credential rotation gone wrong):

```bash
docker compose --env-file environments/dev.env kill db
```

### Detection

- Immediate: `GET /ready` → `{"ready":false,"checks":{"db":"fail: getaddrinfo EAI_AGAIN db","queue":"ok"}}`
  (fail-fast, HTTP 200 with `ready:false` — the pipeline health-gate contract).
- `DBUnavailable` → **firing** ~1m (`mongodb_up==0 or up{job="mongodb"}==0`);
  `ConfigFailure` (`api_ready==0 for 2m`) → pending at 83s, firing by ~2m.
  Two independent signals — exporter liveness + logical readiness — agree.

### Investigation

- `api /ready` detail names the dependency (`db` fail, `queue` ok) — no
  guessing which datastore is at fault.
- Creates during outage return **503** (verified live) — fail loudly, never
  silently drop. Queue stays intact; worker idles without crashing.
- Prometheus `ALERTS{DBUnavailable|ConfigFailure}` is the detection evidence;
  container `ps` shows `db` killed.

### Root cause

Database process absent (simulated host failure). Contributing design fact:
single Mongo instance with no replica set — accepted Compose-scope boundary
(`SPOF.md`), mitigated by named volume + backup/restore drill.

### Recovery

```bash
docker compose --env-file environments/dev.env up -d db
# /ready → {"ready":true,"checks":{"db":"ok","queue":"ok"}}
# POST /appointments → 200 queued; queue_depth 0; SMOKE OK
```

Zero data repair: the named volume survived the kill; unacknowledged work
resumed. Least-privilege users (`api_user`/`worker_user`) reconnected without
credential changes.

### Verification

- `ALERTS{DBUnavailable|ConfigFailure}` → 0 active series (ALL RESOLVED).
- `SMOKE OK` (`errors_total: 1` is the expected single 503 during the window —
  evidence the fail-fast path engaged, not a regression).
- Fresh appointment `queued` → drained to 0.

### Prevention

1. `DBUnavailable` + `ConfigFailure` alerts now cover detection (this incident
   is the proof they fire and resolve).
2. `backup-mongo.sh` (daily cron) + `backup-volumes.sh` (full state +
   SHA256SUMS) + `full-recreate.sh` (`--drop` full-disaster variant) cover
   data loss beyond process death.
3. `POSTGRES-PLAN.md` documents the replica-set/PITR upgrade path
   (DocumentDB/Atlas in real cloud) — the residual single-instance SPOF is
   explicit, not hidden.

## Reproducibility checklist (all three incidents)

- [ ] Dev stack + monitoring up, queue at 0, note wall-clock start.
- [ ] INC-01: `stop worker` → `workload.py 30` → poll queue + `ALERTS` → `up -d worker` → drain 0 → alerts clear → smoke.
- [ ] INC-02: `EHR_MODE=unavailable up -d ehr-mock` → sustained creates (~4 min) → `EHROutage` fires → outcome mix + degraded count → `EHR_MODE=ok` recreate → ok outcomes resume → alert resolves → smoke.
- [ ] INC-03: `kill db` → `/ready` false + 503 on create → `DBUnavailable` firing (~1m), `ConfigFailure` firing (~2m) → `up -d db` → `/ready` true → fresh create 200 → alerts resolve → smoke.
- [ ] Expected timings: WorkerDown fires ~1.5 min after stop; QueueBacklog ~2.5 min;
  EHROutage ~2 min after sustained non-ok ratio; DBUnavailable ~1m, ConfigFailure ~2m;
  resolution ≤ 6 min after recovery.
