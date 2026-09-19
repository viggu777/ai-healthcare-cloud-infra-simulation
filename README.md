# AI Healthcare Cloud Infra Simulation — Phases 1–4 (MERN backend)

Local production-style simulation. FOSS only, Ubuntu + Docker.

## Scope (implemented)
Foundation simulation environment:
- Mock services (Node.js 22 + Express, no frontend per spec): `api` (public via gateway), `ai-service`, `worker`, `ehr-mock` (all private)
- Data: **MongoDB 7** (private, persisted volume) + Redis 7 queue (private)
- Ingress: Nginx gateway = sole public entry (`GATEWAY_PORT`, default 8080)
- Networks: `public` (gateway+api+grafana/nginx-exporter admin) and `private` (internal: true — all services; monitoring scrapes here)
- Env separation without duplication: `docker-compose.yml` base + `environments/dev.env` / `prod.env`
- Health/readiness/metrics on every service; smoke + workload + k6 scripts
- Observability: Prometheus + Grafana (127.0.0.1:3000 dev / :3001 prod-like) + Alertmanager + Pushgateway + 3 exporters, 14 alert rules, 17-panel dashboard, 8 scrape targets (api/worker/ai-service/ehr-mock/nginx/redis/mongodb/pushgateway)

## Quickstart
```bash
docker compose --env-file environments/dev.env up --build -d
bash scripts/smoke.sh
python3 scripts/workload.py http://localhost:8080 20
docker compose --env-file environments/dev.env ps
docker compose --env-file environments/dev.env logs --tail=50
```

Independent scaling:
```bash
docker compose --env-file environments/dev.env up -d --scale api=2 --scale worker=2
```

Prod-like:
```bash
docker compose --env-file environments/prod.env up --build -d  # gateway on 8081
GATEWAY_URL=http://localhost:8081 bash scripts/smoke.sh
```

Teardown/recreate (reproducibility):
```bash
docker compose --env-file environments/dev.env down
docker compose --env-file environments/dev.env up --build -d
```
DB persists via `mongodb_data` volume unless `docker volume rm` is used.

## Secrets
Never hardcoded. Provided via env files; `.env.example` documents keys with placeholders.
Change `MONGO_PASSWORD` and `AI_API_KEY` before any shared use.

## Phases
- Phase 1 (done): foundation above (re-validated after MERN port — see `docs/PHASE1-RESULTS.md`)
- Phase 2 (done): hardening + security validation (non-root audit, Trivy, secret scan, infra lint) — `bash scripts/security-scan.sh` (32/0), report in `docs/SECURITY.md`
- Phase 3 (done): DevSecOps pipeline + safe releases — `bash scripts/pipeline.sh` (executed) + `.github/workflows/pipeline.yml` (CI twin); digest pins, Trivy app-dep gate, SHA tags, rollback; demos in `docs/CICD.md`
- Phase 4 (done): observability (Prometheus/Grafana/Alertmanager/exporters, 14 rules, dashboard) + k6 load/scaling measurements (`docs/RESILIENCE.md`) + 3 incident lifecycles (`docs/INCIDENTS.md`) + backup/restore drill + SPOF/cost/audit (`docs/SPOF.md`) — walkthrough in `docs/DEMO.md`
- Hardening add-ons: nginx dynamic DNS (API scale fix), ai-service/ehr-mock scrape + AIUnavailable/EHRMockDown/ConfigFailure/SaturationWarning alerts, per-service Mongo users + `check-outbound.sh`, `POSTGRES-PLAN.md`, `AI-USAGE.md`, autoscale/canary/log-bundle/volume-backup/secret-rotation scripts

See `docs/TARGET_ARCHITECTURE.md`, `docs/MERN-MIGRATION.md`, `docs/CICD.md` and `docs/DEMO.md`.
