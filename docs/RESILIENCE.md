# Load, Scaling & Backup — Phase 4 measurements (2026-09-19, dev)

All runs against the dev gateway (`:8080`) on the 4-CPU / 7.6 GB host.
Baselines from `scripts/workload.py` on the Node stack: **avg ~16 ms, p95 ~22 ms,
queue drains to 0** (`docs/MERN-MIGRATION.md`). k6 ran from its pinned image:
`grafana/k6:1.0.0@sha256:f21270…` via `docker run --rm -i --network host`.

## 1. Normal load — `k6/smoke.js` (5 VUs, 60 s)

`docs/load-evidence/k6-smoke.txt`: **588 requests, 0 failed, avg 11.1 ms,
p90 16.0 ms, p95 39.8 ms** (max 130 ms single outlier at connection setup),
9.7 req/s. Same performance class as the workload.py baseline — no regression
from the Phase 4 metrics endpoints.

## 2. Increased load — `k6/load.js` (ramp 5→8→12 VUs, 85 s)

`docs/load-evidence/k6-load.txt`: **569 requests, 0 failed, avg 7.1 ms,
p95 17 ms**, 6.6 req/s. The headline result: **API latency is independent of
backlog** — enqueue (Mongo insert + Redis push) never waits for processing, so
even with 302 jobs banked the gateway answered in single-digit milliseconds.
Post-run `queue_depth: 302`.

During both runs the `QueueBacklog` alert went pending → **firing**
(17:18:03–17:18:33, captured from Prometheus `ALERTS` history) → resolved —
the first genuine fire/resolve cycle of the Phase 4 alerting.

## 3. Drain rates & consumer scaling (measured)

| Consumers | Backlog | Drain time | Rate |
|---|---|---|---|
| 1 worker | 375 → 0 | ~105 s | **~3 jobs/s** |
| 2 workers (`--scale worker=2`) | 302 → 0 | ~45 s | **~6.7 jobs/s (≈2.2×)** |

Each job costs ~300 ms simulated work + EHR call + 2 Mongo writes on a single
consume loop (`WORKER_CONCURRENCY` remains advisory — carried from Phase 1).
Consumer scaling is effectively linear; producer/consumer decoupling via Redis
is what makes bursts survivable.

## 4. Bottleneck found: Nginx static upstream DNS (measured)

With `--scale api=2`, 60 requests distributed **60 → replica-1, 0 → replica-2**
(per-replica `requests_total` before/after, `docs/load-evidence/nginx-scale-observation.txt`).
Nginx resolves the `api` upstream once at startup/reload and pins the first IP,
so a scaled API gets **zero** traffic on new replicas. Remediation (not built):
`resolver` directive with short TTL + variable-based `proxy_pass`, or a real
ingress in cloud. Until then: scale the *workers* (proven linear above), not
the API — and treat `--scale api=N` as validated-but-ineffective, exactly as
flagged since Phase 1 (`docs/TARGET_ARCHITECTURE.md` §14).

**2026-09-19 re-test after partial remediation** (`resolver 127.0.0.11 valid=10s`
+ variable `proxy_pass` + `proxy_next_upstream`, commit `c744877`): with
`--scale api=2`, two consecutive batches of 20 × `POST /appointments` via the
gateway distributed **44 → replica-1, 0 → replica-2** (per-replica
`api_requests_total`; `POST` is the only route that increments the counter —
`GET /metrics/prom` does not). Docker DNS itself rotates (`getent hosts api`
returned `.3` then `.6` on successive queries), but nginx OSS caches one IP per
10 s window, so every request inside the window pins to one replica. Improvement
over startup-pin: rescheduled/recreated `api` containers are picked up within
~10 s with no gateway reload, and 502/503 fails over via
`proxy_next_upstream`. Per-request round-robin remains future work (real
ingress); the guidance stands — scale workers, not the API.

## 5. Resource usage (measured, `docs/load-evidence/docker-stats-load.txt`)

| Container | CPU (during load) | Memory |
|---|---|---|
| api | ~0.1% | ~49 MB |
| worker (each) | ~2–13% | ~35–39 MB |
| queue (redis) | ~1% | ~7 MB |
| db (mongo) | ~3% | ~99 MB |
| prometheus | ~0% | ~44 MB |
| grafana | ~0.1% | ~75 MB |

The whole dev stack idles under ~400 MB; exporters are ~15–20 MB images at
single-digit MB RSS. Headroom is ample on the 7.6 GB host — see cost notes in
`docs/SPOF.md`. Image sizes (compressed): prometheus 440 MB, grafana 873 MB,
alertmanager 110 MB, pushgateway 39 MB, exporters ~15–20 MB each, k6 115 MB.

## 6. Backup / restore drill — `scripts/backup-mongo.sh`, `restore-mongo.sh`

Both use an ephemeral digest-pinned `mongo:7-jammy` container on the private
network (`mongodump`/`mongorestore`, `--out/--dump` via bind mount); no host
Mongo install. Fresh drill transcript (dev, 2026-09-19):

```
baseline:  appointments=1519            # 70 from last down/up + Phase 3/4 traffic
backup:    backups/drill-p4 (appointments.bson + jobs.bson + metadata) — 1519 docs dumped
loss:      deleted=100 → remaining=1419
restore:   100 document(s) restored … 2938 failed* → count=1519
verify:    appointments=1519, jobs=1519, SMOKE OK
```

\* `mongorestore` without `--drop` upserts by `_id`: the 100 deleted documents
restored, the 2938 already-present ones report duplicate-key "failures" (skips,
not corruption — counts prove it). No-`--drop` is deliberate: anything written
between backup and restore survives. Full-disaster variant (wiped volume): same
command plus `--drop`, then verify counts against the backup log.

Two drill fixes worth recording: the image runs as uid 999, so the script
`chmod 777`s the fresh output dir and loosens the dump (`chmod -R a+rw` via an
ephemeral root container) — otherwise the host admin can neither write nor
clean up `backups/`. Simulation-grade, documented in the scripts.

RPO/RTO posture (stated, not enterprise): RPO = time since last `backup-mongo.sh`
(manual cadence; no scheduler built — cron/systemd timer is the documented next
step); RTO = minutes (one `restore-mongo.sh` run, ~seconds at this data volume).
