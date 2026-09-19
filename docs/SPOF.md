# SPOF Analysis, Cost Awareness & Operational Auditability — Phase 4

Risk language reuses `docs/SECURITY.md` §5 (R1–R7); nothing here starts a
parallel taxonomy. Residual R-items are referenced inline.

## 1. Single-point-of-failure analysis

| Component | Fails how | Blast radius | Mitigation (built) | Residual |
|---|---|---|---|---|
| **API** (1 replica default) | Crash/OOM → gateway 502s | Creates rejected; reads stale-fail | Health-gated deploys; `/ready` fail-fast; `--scale` path exists but see §4 | Single replica by default; scale-out proven *ineffective* via gateway (§4) |
| **Worker** (1 replica default) | Stop/crash → backlog grows | Latency of processing, not loss (Redis holds jobs) | `restart: unless-stopped` (P0.2: crash auto-revives, verified <1 s + auto-drain); WorkerDown + QueueBacklog alerts; linear `--scale worker=N` (measured 2.2×) | Explicit `stop` still holds the worker down (INC-01 window); no autoscaler (manual `--scale`) |
| **Queue** (single Redis, AOF volume) | Process death → API 503s, worker idle | Full async stall; in-memory unflushed tail at risk | AOF persistence; `/ready` fails fast instead of dropping; no `cap_drop` exception documented (R3) | Single instance; no replica/sentinel (Compose scope) |
| **Database** (single Mongo, named volume) | Death/corruption → API+worker 503s | State plane down; data at volume risk | Named volume; `backup-mongo.sh`/`restore-mongo.sh` drilled (RPO = backup cadence); DBUnavailable alert | Single instance; no replica set; SSPL image (R6) |
| **EHR mock** (external dependency stand-in) | `unavailable`/timeout storm | Jobs degrade (`processed_ehr_degraded`), never lost | Outcome-mix telemetry + EHROutage alert; retry/timeout bounds in worker | No circuit-breaker yet (documented next step, INC-02) |
| **Deployment system** (pipeline.sh / Actions) | Bad gate or bad tag | Blocked releases (safe) or rolled-back deploy (safe) | Every post-build failure restores the previous tag; traceability table per run | Git history exists (P0.1) so tags are real SHAs; no git remote yet → Actions twin unexecuted (P1.7) |
| **Monitoring** (Prometheus/Grafana/Alertmanager) | OOM/misconfig | Blind ops — app keeps serving (data plane independent by design) | Tiny retention (7d/1GB); firing state also queryable via Prom API; app never depends on monitoring | Alertmanager receiver is a discard webhook (real paging is future work) |

Cross-cutting: the **host itself** is the ultimate SPOF (single Ubuntu box —
stated since Phase 1, `docs/TARGET_ARCHITECTURE.md` §14). Everything above is
container-level resilience *within* that accepted boundary.

## 2. Alert catalog (all in `monitoring/alerts.yml`, each with runbook annotation)

| Alert | Severity | Fires when | Operator action (short) |
|---|---|---|---|
| APIUnavailable | critical | `up{job=api}==0` 1 m | Logs → restart api; queue holds work |
| HighErrorRate | warning | error ratio > 5% 2 m | 422s = payloads; 503s = deps; rollback if deploy-caused |
| ExcessiveLatency | warning | mean latency > 500 ms 2 m (baseline ~16 ms) | Queue vs DB vs CPU; scale workers |
| WorkerDown | critical | `up{job=worker}==0` 1 m | Restart worker; watch drain (proven INC-01) |
| QueueBacklog | warning | depth > 15 for 2 m | Check worker/EHR; `--scale worker=N` |
| DBUnavailable | critical | `mongodb_up==0` or exporter down 1 m | Restart db; restore from backup if data lost |
| DeploymentFailed | critical | `pipeline_last_run_success==0` | Read run log in `docs/pipeline-evidence/`; fix gate; re-run |
| SecurityScanFailed | critical | `security_scan_last_success==0` | Run scan locally; rotate/bump/fix; never allowlist |
| EHROutage (bonus) | warning | non-ok EHR ratio > 20% 2 m | Outcome mix tells which; 401 first; see INC-02 |

Firing history is queryable (`ALERTS` metric) and surfaced on the Grafana
"Firing alerts" panel — QueueBacklog's first genuine cycle (pending → firing →
resolved) came from the Phase 4 load tests.

## 3. Cost awareness (measured, PDF §22)

Everything remains free/open-source/self-hosted: **€0 cloud spend by construction**.
The demonstrated trade-off is local compute, now measured instead of estimated
(`docs/RESILIENCE.md` §5): dev stack idles < 400 MB RAM; monitoring adds
~150 MB (Prometheus 44 MB + Grafana 75 MB + exporters); per-image disk is
dominated by Grafana (873 MB) and Prometheus (440 MB) — the "cost" of
observability here is disk, not RAM. Retention is capped (7 d / 1 GB) so disk
stays bounded; the worker-replica dial is the only knob that would cost real
money in cloud, and §3–§4 characterize exactly what each replica buys
(~3 jobs/s, linear). Host disk was 94% full at Phase 4 start — the binding
constraint on this box is disk, and old image tags are the thing to prune.

## 4. Operational access & auditability (who/what/when)

- **Who deployed what:** every image carries its run tag (SHA in CI,
  timestamped locally); each pipeline run ends with a per-env image-tag table;
  run logs live in `docs/pipeline-evidence/` (4 runs: healthy, blocked-secret,
  broken-ready, p4-final-01).
- **Which checks ran:** lint/unit/security-gate/trivy/health-gate/smoke/workload
  results are in the same logs; `security-scan.sh` evidence in
  `docs/security-evidence/`.
- **When incidents occurred:** INC-01 (17:23–17:28) and INC-02 (17:29–17:41)
  with wall-clock timelines in `docs/INCIDENTS.md`, cross-checkable against
  Prometheus `ALERTS` history and container logs.
- **What recovery happened:** rollback tags (Phase 3 log), worker restart +
  drain (INC-01), EHR mode restore (INC-02), 100-doc delete + restore with
  before/after counts (RESILIENCE §6).
- Access control stays simulated (no IAM): networks + non-root + per-env
  placeholder creds (R4) + localhost-bound Grafana (admin-only). No real secrets
  anywhere — Gitleaks-clean, re-verified 26/0 after all Phase 4 changes.

## 4b. Security posture notes (Phase 4 additions)

- 7 new images, all version- **and digest-pinned** (R5 stays closed).
- Grafana's `127.0.0.1`-bound port is a documented `compose-lint` warn-only
  exception (was: fail); lint now distinguishes localhost-bound (warn) from
  publicly reachable (fail): **70 pass / 0 fail / 4 warn**.
- Two Docker behaviors found and recorded: (1) containers on `internal:true`
  networks **cannot publish ports** (binding silently dropped) — hence Grafana
  and nginx-exporter are dual-net like `api`; (2) Gitleaks `-v` reports
  self-contaminate (Phase 3 fix retained).
