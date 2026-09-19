# PostgreSQL Migration Playbook (relational option for PRD §3)

Status: plan only — MongoDB 7 remains the running datastore (see
`TARGET_ARCHITECTURE.md §13`, `SECURITY.md §1`). This playbook proves the
relational requirement can be met without architectural redesign, because the
database's *infrastructure role* (private, internal-only, health-checked,
backed up) is engine-independent.

## Why this is a playbook, not a migration

PRD §3 asks for a relational DB; §2/§27 say the assessment is infrastructure,
not data modeling, and the full healthcare model is explicitly not required.
Swapping engines is a data-layer rebuild (schema, queries, init, backup,
exporter) — correctly scoped as a standalone phase, not smuggled into
hardening or observability work.

## Step-by-step

1. **Compose**: replace `db` image `mongo:7-jammy@sha256:…` with
   `postgres:16-bookworm@sha256:<repin>`; keep `private` net, no ports,
   named volume `postgres_data`; healthcheck `pg_isready -U $POSTGRES_USER`.
2. **Init**: replace `db/mongo-init.js` with `db/migrations/001_init.sql`
   (`appointments(id TEXT PK, patient TEXT, doctor TEXT, status TEXT,
   created_at TIMESTAMPTZ, updated_at TIMESTAMPTZ)`,
   `jobs(id TEXT PK, type TEXT, status TEXT, attempts INT, …)` + indexes
   on `(status, created_at)`).
3. **App**: replace `mongodb` driver with `pg` (connection pool, 3 s
   `statement_timeout`); `insertOne/updateOne/find` → parameterized
   `INSERT … ON CONFLICT DO NOTHING / UPDATE / SELECT … LIMIT`.
   Keep endpoint contracts byte-identical (`/health /ready /metrics`).
4. **Least-privilege**: `api_user` (INSERT/SELECT/UPDATE on both tables),
   `worker_user` (SELECT/UPDATE), `exporter` (pg_monitor) — mirrors the
   current `api_user/worker_user` split.
5. **Observability**: `percona/mongodb_exporter` → `prometheuscommunity/postgres-exporter`;
   `mongodb_up` → `pg_up` in `DBUnavailable`; dashboard panel + runbook updated.
6. **Backup**: `mongodump/restore` → `pg_dump -Fc / pg_restore`; RPO/RTO
   re-drilled with the same 1519-doc count method (`RESILIENCE.md §6`).
7. **Pipeline/IaC**: digest repin + `trivy-gate.sh` unchanged (lang-pkgs
   gate covers `pg`); `terraform/` resource notes + `compose-lint.py`
   DB rules updated (still: private-only, no published port).
8. **Proof**: `smoke.sh` + `workload.py 20` + `k6/smoke.js` green, queue
   drains to 0, INC-01/INC-02 re-runnable, `security-scan.sh` PASS.

## Effort

~0.5 day (schema + driver swap + backup re-proof). No change to gateway,
networks, queue, CI gates, alerts topology, or scaling story.
