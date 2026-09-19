# Demo Script — evaluator walkthrough (start to finish, ~45 min)

Everything below runs on the Ubuntu host with Docker; free/open-source only.
Timings are wall-clock from the 2026-09-19 runs. Steps marked *(deep)* are
optional elaborations — the story works without them.

Conventions: `D="docker compose --env-file environments/dev.env"`,
`P="docker compose --env-file environments/prod.env"`.

## 0. Setup (2 min)

```bash
cd /home/viggu/Documents/ai-healthcare-cloud-infra-simulation
export DOCKER_CONFIG=/tmp/docker-nocreds   # host-cred-helper workaround, see docs/PHASE1-RESULTS.md
$D up -d                                    # dev on :8080, incl. monitoring
$D ps                                       # 14 services: 7 app + 7 observability
```

## 1. Normal operation (3 min)

```bash
bash scripts/smoke.sh                        # SMOKE OK via gateway only
python3 scripts/workload.py http://localhost:8080 20
# enqueued=20 avg~16ms p95~22ms, queue drains to 0
curl -s http://localhost:8080/metrics | head -c 300
```

## 2. Architecture & network boundaries (3 min)

- Diagram: `docs/TARGET_ARCHITECTURE.md` §2 (single primary diagram).
- Prove sole ingress: `docker ps --format '{{.Names}} {{.Ports}}'` — only
  `...-gateway-1` has a host port. Direct `:8001` refused:
  `curl -m 3 http://localhost:8001/health` → connection refused.
- Prove isolation: `python3 scripts/compose-lint.py` → 70 pass / 0 fail / 4 warn
  (warns are documented exceptions: gateway/db/queue caps, Grafana localhost port).
- Observability: open `http://127.0.0.1:3000` (admin/dev_only_change_me) —
  "AI Healthcare Sim — Overview": API/worker/queue/DB/EHR/deployment panels;
  Prometheus targets: `docker exec ai-healthcare-dev-prometheus-1 wget -qO- http://localhost:9090/api/v1/targets?state=active`
  (6/6 up); rules (`.../api/v1/rules`): 9 loaded.

## 3. IaC recreation (3 min)

```bash
$D down && $D up -d && sleep 20 && bash scripts/smoke.sh   # SMOKE OK
# Mongo volume persists: appointment count survives (drill: docs/RESILIENCE.md §6)
```

## 4. CI/CD + security gate (5 min)

```bash
bash scripts/security-scan.sh     # PASS 26/0 (gitleaks + trivy + lint, one command)
bash scripts/trivy-gate.sh        # app-dep gate PASS; OS baseline reported, non-blocking
```

*(deep)* Blocked release: the seeded-secret demo —
`docs/pipeline-evidence/pipeline-p3-demo-blocked-secret.log`
(25/1 FAIL at security stage, dev untouched). Do NOT re-run with a live seed
unless you follow the redaction/recovery notes in `docs/CICD.md` §7.

## 5. Healthy deploy (10 min)

```bash
bash scripts/pipeline.sh --tag demo-$USER --workload 10
# lint → unit (6/6) → security 26/0 → trivy gate → build → deploy dev →
# health gate → smoke → workload → promote prod-like (:8081) → smoke → PASS
GATEWAY_URL=http://localhost:8081 bash scripts/smoke.sh   # prod-like serves new tag
```

## 6. Induced failure + detection + recovery (10 min) *(deep: full INC-01)*

```bash
$D stop worker
python3 scripts/workload.py http://localhost:8080 30   # queue → 30, API still fast
# watch: queue_depth frozen; WorkerDown fires ~1.5 min, QueueBacklog ~2.5 min
# (Grafana "Firing alerts" panel or the ALERTS API query in docs/INCIDENTS.md)
$D up -d worker                                        # backlog 30 → 0 in ~20 s
# alerts resolve; bash scripts/smoke.sh → SMOKE OK
```

## 7. Broken deploy blocked & rolled back (2 min reading)

Full transcript: `docs/pipeline-evidence/pipeline-p3-demo-broken-ready.log` —
bad `/ready` → health-gate timeout → previous tag restored and verified serving,
prod-like never touched. (Re-running takes ~5 min incl. the 120 s gate timeout;
source-safe: the demo restores `services/api/server.js` byte-identical.)

## 8. Trade-offs summary (read, 5 min)

1. **MongoDB instead of relational** (spec §3): deliberate, twice-reaffirmed
   deviation — infrastructure role identical, engine swappable later.
   `docs/TARGET_ARCHITECTURE.md` §13, `docs/SECURITY.md` §1.
2. **EHR `slow` = 2 s, not 3 s**: Node timers always lose a 3000-vs-3000 ms race,
   collapsing `slow` into `timeout`; 2 s preserves the slow→200 contract.
   `docs/MERN-MIGRATION.md`.
3. **Nginx static upstream DNS**: scaling `api=2` sends 60/60 requests to one
   replica (measured, `docs/RESILIENCE.md` §4). Scale workers instead (linear,
   measured 2.2×).
4. **Single host, no IAM, no autoscaler, discard-webhook paging**: accepted
   simulation boundaries, each with its real-cloud mapping in §14/SPOF.
5. **No frontend / real AI / real EHR / real data / real cloud**: permanently out
   of scope (spec §26) — none exists anywhere in the repo.

## Cleanup

```bash
$D down        # volumes persist; add -v only to wipe state deliberately
$P down
```
