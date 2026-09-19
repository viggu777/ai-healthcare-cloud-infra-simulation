# MERN Migration — Decision & Change Log (2026-09-19)

Per instruction, the runtime was migrated from Python/FastAPI to **Node.js 22 + Express**
(MERN backend: MongoDB + Express + Node + Redis + Nginx/Compose) **during** Phase 2.
**No React/frontend**: spec §26 explicitly excludes healthcare frontends, patient/hospital/
doctor UIs — adding one would create scope and attack surface for zero spec credit.

## What changed

| Area | Before (Python) | After (Node) |
|---|---|---|
| `api` :8000 | FastAPI + pymongo + redis + httpx (`app.py`) | Express 4.22.3 + mongodb 6.21.0 + ioredis 5.11.1 (`server.js`) |
| `ai-service` :8001 | FastAPI (`app.py`) | Express 4.22.3 (`server.js`) |
| `ehr-mock` :8002 | FastAPI (`app.py`) | Express 4.22.3 (`server.js`) |
| `worker` :8003 | `worker.py` (http.server health) | `worker.js` (bare-`http` health, same contract) |
| Dockerfiles | `python:3.12-slim-bookworm`, `USER appuser`, pip | Multi-stage `node:22-slim`, `npm ci --omit=dev`, `USER node`, npm stripped |
| Healthchecks | `python -c urllib...` | `node -e fetch(...)` |
| Scan gates | Python-aware audits | Node-aware audits (`USER node`, `node:22-slim`) |

Unchanged: MongoDB 7 + data (same collections/docs, no migration), Redis 7, Nginx gateway +
`nginx.conf`, Compose topology/networks/volumes, all env var names, `cap_drop`/`security_opt`
policy, `.dockerignore` policy, `smoke.sh`/`workload.py` contracts.

## Preserved Phase 2 work

- Snapshot before migration: `docs/security-evidence-python-stack/` + `docs/SECURITY-python-stack.md`.
- Carried over: `.dockerignore` files, `cap_drop ALL` + `no-new-privileges` on the 4 custom
  services, compose-lint rules, one-command `security-scan.sh` (audits updated for Node).

## Intentional behavior changes (1)

1. **EHR `slow` mode sleeps 2s instead of 3s.** The Python mock slept exactly 3000ms against
   a 3000ms client timeout (`EHR_TIMEOUT_S=3`) — a boundary race. Node's precise timers make
   the abort always win (measured: 3/3 → 504 at ~3.00s), collapsing `slow` into `timeout`
   and contradicting the demonstrated Phase 1 contract (`slow` → 200 `slow-but-ok`).
   2s keeps `slow-but-ok` inside the deadline while `timeout` (10s) still exceeds it.
   Verified post-change: `slow` → 200 in ~2.0s on dev and prod-like.

## Incidental differences (accepted)

- Validation errors: FastAPI returned 422 `{"detail":[...]}` via pydantic; Express returns 422
  `{"detail":"patient and doctor are required strings"}`. Same status, simpler body.
- `uptime_s`/`avg_latency_ms` rounding equivalent (1 decimal / 2 decimals).
- Image sizes up (332–345MB vs 221–244MB): Node runtime + `node_modules` (mitigated by
  multi-stage + npm strip). OS CVE totals moved 60H/5C → 52H/4C with the rebase.
- `WORKER_CONCURRENCY` remains advisory (single consume loop, as in `worker.py`).

## Relational-DB deviation (recorded)

Spec §3 asks for a relational database; the project uses MongoDB 7 (Phase 1 decision:
document/job JSON fit, flexible schema, persisted volume, private-only). The MERN port
**reaffirms** this: the Node `mongodb` driver uses identical collections/document shapes,
so no data migration was required and Phase 1 persistence evidence (70 appointments across
`down/up`) still holds. See `docs/SECURITY.md` §1.

## Test evidence (all actually run 2026-09-19, Node stack)

smoke dev OK · workload-20 drained 19→0 · AI 200 + wrong-key 401 · EHR all 7 modes correct ·
isolation (sole gateway port, `:8001` refused, `internal:true`) · `--scale api=2 worker=2` OK ·
worker stop → backlog 5 → restart → 0 · `down/up` 70/70 persisted · prod-like :8081 SMOKE OK,
dev unaffected · `security-scan.sh` PASS 26/0 · Trivy npm 0 findings · Gitleaks clean ·
compose-lint 42/0/3-warn-documented.
