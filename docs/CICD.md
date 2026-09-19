# CI/CD — Phase 3: DevSecOps Pipeline + Safe Releases

Date: 2026-09-19 · Stack: Node.js 22 + Express, MongoDB 7, Redis 7, Docker Compose, Nginx
Status: **Done** (healthy rollout + security-blocked release + unhealthy-rollback all demonstrated with logs)

## 1. Which artifact was chosen and why

**Both exist; each has a defined role:**

| Artifact | Role | Executed? |
|---|---|---|
| `.github/workflows/pipeline.yml` | CI definition: runs on push/PR/`workflow_dispatch` with `github.sha` tags against two ephemeral Compose projects on the runner | **Yes — green on a connected clone (P1.7): [Actions run 35449680652](https://github.com/viggu777/ai-healthcare-cloud-infra-simulation/actions/runs/35449680652)** (private repo `viggu777/ai-healthcare-cloud-infra-simulation`, `main`, 3m47s: lint → audit → security → build → Trivy gate → deploy dev → health gate → promote prod-like) |
| `scripts/pipeline.sh` | Local runnable equivalent: identical stage order, identical gates, identical rollback semantics against the same Compose files on the Ubuntu host | **Yes — all three demonstrations below ran through this script** |

No stages were reimplemented: the pipeline calls `scripts/security-scan.sh` as-is and
`scripts/smoke.sh` as the baseline health check, exactly as the execution brief requires.

## 2. Stage map (both artifacts)

```
lint → unit → security-scan.sh (as-is) → build (run-tagged)
  → trivy-gate.sh on NEW images (binding) → deploy dev → health gate (/ready via
  gateway) → smoke → workload → promote prod-like → post-promote smoke → rollback
  to previous tag on failure at any post-build stage
```

| Stage | Command | Gate? |
|---|---|---|
| lint | `node --check` on all 7 service sources + `compose config -q` (dev + prod-like + prod resources override) | Yes — any failure stops the run |
| unit | `node --test services/api/validate.test.js` (6 tests, zero deps) | Yes |
| dependency audit | `npm audit --omit=dev --audit-level=high` per service (api, ai-service, worker, ehr-mock, alert-logger) | Yes — any HIGH/CRITICAL stops the run |
| security | `bash scripts/security-scan.sh` (Gitleaks + Trivy report + compose-lint, 26/0) | Yes |
| build | `APP_VERSION=<run-tag> compose build api ai-service worker ehr-mock` | Yes |
| trivy gate | `bash scripts/trivy-gate.sh --tag <run-tag>` | **Yes — exit-code gate on app deps (see §3)** |
| deploy dev | `APP_VERSION=<run-tag> compose --env-file environments/dev.env up -d` | Previous dev tag snapshotted first |
| health gate dev | Poll `/ready` via gateway (default 120 s) → `smoke.sh` → `workload.py <gw> 10` | Yes — failure triggers rollback |
| promote prod-like | Same deploy against `environments/prod.env` (:8081) **layered with `docker-compose.prod.yml`** (P1.6: CPU/memory limits on the 5 Node services — the cost dial) | Previous prod-like tag snapshotted first |
| post-promote check | Health gate + `smoke.sh` on :8081 | Yes — failure triggers rollback |

There are intentionally **no `--skip` flags** for lint/unit/security: gates that can be skipped are not gates.

## 3. Trivy `--exit-code` gate semantics (`scripts/trivy-gate.sh`)

Phase 2 runs Trivy as a *report* step because the Debian bookworm OS layer carries
52 HIGH / 4 CRITICAL findings with no upstream fix (`docs/SECURITY.md` R1, accepted +
mitigated) — a blanket `--exit-code 1` would fail every build forever. This gate closes
Phase 2's R5 with a split verdict, parsed from Trivy JSON per image:

- **`lang-pkgs` (our `node_modules`: express, mongodb, ioredis) — BLOCKING.** Any
  HIGH/CRITICAL finding exits 1 and stops the pipeline before any deploy.
- **OS layer (`debian`) — reported, non-blocking.** Current baseline 56 per image,
  accepted per R1.

Current state: 0 app-dependency findings on all 4 images → `TRIVY GATE: PASS`.

## 4. Image tagging (traceability)

Every built image carries the **run tag**: the git SHA when run inside a git checkout
(`git rev-parse --short HEAD` — CI uses `github.sha` for the same value), otherwise
`local-<timestamp>`. A semver alias from the env file (`0.1.0-dev` / `0.1.0`) is kept
alongside for humans; running containers always carry the exact run tag, shown in the
traceability table each run ends with. Demo tags used here (`p3-demo-healthy1`, …)
stand in for SHAs from before this repo had git history (P0.1 `git init`); all runs
since P0.1 use real short SHAs (`git rev-parse --short HEAD`).

## 5. Digest pinning (closes Phase 2 R5)

| Base image | Pinned reference |
|---|---|
| `node:22-slim` (all 4 Dockerfiles, both stages) | `node:22-slim@sha256:48e4b67d85f87bd551df43704e24d252f56cc5f8e9718841aace50f19948f0f9` |
| `nginx:alpine` (gateway) | `nginx:alpine@sha256:4870c12cd2ca986de501a804b4f506ad3875a0b1874940ba0a2c7f763f1855b2` |
| `redis:7-alpine` (queue) | `redis:7-alpine@sha256:520775a41a63e77e06c73e35d2fd9cc15921a609516818796b4ecbb813078bc7` |
| `mongo:7-jammy` (db) | `mongo:7-jammy@sha256:84c4a18b60a0e73d1577112b0a600b46cab477c64cfe0ff36d0647bbca055bd0` |

Digests are the images pulled 2026-09-19; repin on rebuild cadence. `security-scan.sh`
still passes **26/0** after pinning. Topology unchanged — the primary diagram
(`docs/TARGET_ARCHITECTURE.md` §2) needed no update.

## 6. Demonstration 1 — healthy rollout (PASS)

```bash
bash scripts/pipeline.sh --tag p3-demo-healthy1 --workload 10
# → ##### RESULT: PASS — tag p3-demo-healthy1 healthy in dev AND prod-like
```

Key log excerpts (`docs/pipeline-evidence/pipeline-p3-demo-healthy1.log`):

- lint: 6× `[lint-ok]` + compose config dev/prod-like OK
- unit: `# pass 6 / # fail 0`
- security: `SECURITY SCAN: PASS (26/0)`; `TRIVY GATE: PASS` (4× app-deps clean)
- dev: health gate READY, `SMOKE OK`, `WORKLOAD DONE` (avg ~16 ms class, queue → 0)
- prod-like: health gate READY, `SMOKE OK` with `"version":"p3-demo-healthy1"`
- traceability table: all 4 custom services on `:p3-demo-healthy1` in both envs;
  infra on digest-pinned images

## 7. Demonstration 2 — security failure blocks release (FAIL, pre-deploy)

Fault: seeded fake private-key block at `scripts/.seeded-fake-secret.tmp` (clearly
labelled fake; deleted after the demo).

```bash
bash scripts/pipeline.sh --tag p3-demo-blocked-secret --no-workload
# → RESULT: 25 passed, 1 failed / SECURITY SCAN: FAIL
# → ##### PIPELINE BLOCKED at stage 'security (security-scan.sh as-is)'
# → ##### RESULT: FAIL — exit 1, build/deploy never reached
```

Verified during the block: dev still served `p3-demo-healthy1` (`/health` + `/ready`
both OK) — the running version was untouched. Full log:
`docs/pipeline-evidence/pipeline-p3-demo-blocked-secret.log`
(the embedded fake-secret text in that log is redacted to `[REDACTED-FAKE-KEY]` —
standard post-incident handling; exit codes, counts and fingerprints are intact).

**Recovery lessons (both fixed during this demo):**

1. Gitleaks `-v` output embeds matched secret text in its own report file
   (`docs/security-evidence/gitleaks.txt`), so a stale FAIL report re-trips the next
   scan. Fix: `scripts/security-scan.sh` now deletes the stale report *before*
   scanning (regenerated by the same step — no detection weakened).
2. The pipeline evidence log captured the same embedded text via `tail -20`; redacted
   as above. Post-recovery `security-scan.sh` → **PASS 26/0** on the strict,
   unweakened scanner (no allowlists added anywhere).

## 8. Demonstration 3 — unhealthy deploy rolled back (FAIL, post-deploy)

Fault: temporary patch to `services/api/server.js` forcing `/ready` to
`{ready:false, checks: INJECTED-BREAK}` (source backed up first, restored
byte-identical afterwards — `diff` clean, `node --check` OK).

```bash
bash scripts/pipeline.sh --tag p3-demo-broken-ready --no-workload
# → build OK, trivy gate OK, deployed to dev
# → health gate (dev): TIMEOUT after 120s
# → ##### PIPELINE BLOCKED at stage 'health gate dev'
# → ROLLBACK: restoring previous tag 'p3-demo-healthy1'
# → rollback-verify: READY after ~0s — previous version serving again
# → ##### RESULT: FAIL — exit 1
```

Verified after rollback: dev serves `p3-demo-healthy1` (`ready:true`);
prod-like still serves `p3-demo-healthy1` — the broken tag never reached promotion
(the `promote prod-like` stage never executed). The broken images were untagged from
the daemon afterwards (`docker rmi …:p3-demo-broken-ready`) to leave no confusion.
Full log: `docs/pipeline-evidence/pipeline-p3-demo-broken-ready.log`.

## 9. Supporting change: testable validation unit

`services/api/server.js` validation was extracted verbatim into
`services/api/validate.js` (same 422 status, same `detail` string — verified live:
422 contract + valid create both OK post-refactor) with `validate.test.js`
(6 cases, `node:test` + `assert` only, no new dependencies). The Dockerfile `COPY`
line was extended accordingly. This gives the pipeline a real unit stage without
changing any endpoint behavior.

## 10. Limitations / next steps (Phase 4)

- CI workflow **executed on GitHub (P1.7, green run linked in §1)** — including two real twin-only findings fixed along the way (trivy-gate `--tag` space-form parsing; per-job fresh runners needing per-job TLS cert generation).
- `prod-like` is a second Compose project on the same host, not a separate host —
  promotion mechanics are real, blast radius is simulated (consistent with §14).
- No autoscaler; load characterization (k6) and the remaining PDF rows move to Phase 4.

## 11. Phase 4 addendum (2026-09-19)

- **Pipeline→monitoring wiring:** `pipeline.sh` now pushes `pipeline_last_run_success`,
  `pipeline_last_run_timestamp_seconds`, `security_scan_last_success` to Pushgateway
  (through the api container over stdin — the only path onto the private net),
  feeding the `DeploymentFailed` / `SecurityScanFailed` Alertmanager rules and the
  Grafana dashboard. The GH workflow mirrors the pushes (success + rollback paths).
- **Push bug found and fixed:** the first implementation passed the payload via
  `docker exec` argv; the body arrived truncated (Pushgateway 400 "unexpected end
  of input", fetch still resolving "pushed"). Stdin pipe verified 200; function
  rewritten, test push groups (`dbg*`, `repro-test`) deleted from Pushgateway.
  The `p4-final-01` values in Prometheus were backfilled with the fixed path
  (identical values the run would have pushed).
- **Final regression:** `pipeline.sh --tag p4-final-01 --workload 10` → **PASS,
  exit 0** with all Phase 4 code in place (lint, unit 6/6, security 26/0, trivy
  gate, dev + prod-like smoke). Log: `docs/pipeline-evidence/pipeline-p4-final-01.log`.
- Load/scaling measurements, incidents, backup drill: `docs/RESILIENCE.md`,
  `docs/INCIDENTS.md`; evaluator walkthrough: `docs/DEMO.md`.
