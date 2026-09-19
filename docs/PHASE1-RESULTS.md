# Phase 1 results (dev + prod-like, MongoDB)

Stack at Phase 1 sign-off: Docker Compose, Nginx gateway, FastAPI api/ai/ehr-mock, Python worker, Redis 7 queue, MongoDB 7.
Change per request: Postgres replaced with MongoDB (`MONGODB_URI`, `mongodb_data` volume, `db/mongo-init.js`).

## Tests (all passed, Python stack)
- `config` dev + prod-like: OK
- `up --build`: all 7 services healthy (gateway fix: healthcheck uses 127.0.0.1, IPv6 localhost refused)
- Smoke via gateway only: health, ready (db+queue ok), create+list appointment, metrics — OK
- Workload 20: avg ~10ms, p95 ~11ms, queue 19→0 drained — OK
- Isolation: only gateway publishes host port (8080 dev / 8081 prod); private net `internal:true`; direct :8001 refused — OK
- AI/EHR via gateway: ai 200, ehr ok/slow(3s)/error(500 retryable) — OK
- Scale `--scale api=2 --scale worker=2`: both healthy, gateway serves — OK (note: nginx upstream static DNS, add resolver in Phase 3)
- Worker failure: stopped → queue stuck at 10; restarted → drained to 0 — OK
- Recreate `down/up`: 31 appointments persisted in Mongo volume — OK
- Prod-like (8081): healthy, 1 appointment processed — OK; dev unaffected

## Flags (cannot fully satisfy in Phase 1 / Compose)
- No real IAM/RBAC (simulated via networks + non-root + per-env creds)
- No autoscaler (manual `--scale` only)
- Audit = compose logs + image tags (no CloudTrail)
- Mongo image is SSPL (free local use OK; swap later if strict OSI needed)
- Full pipeline/scans/dashboard/alerts/incidents → Phases 2–4, not started per instruction

Docker note: host `credsStore: desktop` breaks pulls (gpg); workaround `DOCKER_CONFIG=/tmp/docker-nocreds` used.

## Addendum — MERN port re-validation (2026-09-19, Node.js 22 + Express, actually run)

Runtime migrated Python → Node during Phase 2 (detail: `docs/MERN-MIGRATION.md`). Full Phase 1
matrix re-run on the Node stack, all passed:
- `config` dev + prod-like: OK
- `up --build`: all 7 healthy (healthchecks now `node -e fetch(...)`) — OK
- Smoke via gateway: OK; workload 20: avg ~16ms, p95 ~22ms, queue drained to 0 — OK
- Isolation: sole gateway port, private `internal:true`, direct :8001 refused — OK
- AI/EHR via gateway: ai 200, wrong-key 401, ehr ok/slow(200)/error(500)/auth_fail(401)/unavailable(503)/timeout(504) — OK (slow mock now 2s; boundary-race fix documented in `docs/MERN-MIGRATION.md`)
- Scale api=2/worker=2: healthy, gateway serves — OK (nginx static-DNS note still holds)
- Worker failure: stopped → backlog 5 → restarted → drained to 0 — OK
- Recreate `down/up`: 70/70 appointments persisted — OK
- Prod-like (8081): SMOKE OK, AI/EHR OK; dev unaffected — OK
