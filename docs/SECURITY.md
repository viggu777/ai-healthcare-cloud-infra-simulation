# Security Report — Phase 2: Hardening + Security Validation

Date: 2026-09-19 · Stack: Ubuntu/Mint + Docker · Runtime: **Node.js 22 + Express** (MERN backend; no frontend per spec §26)
Tools (FOSS): Trivy 0.74.0, Gitleaks 8.30.1 (both via Docker images), custom `scripts/compose-lint.py` (stdlib only)
One-command gate: `bash scripts/security-scan.sh` → **PASS (26 passed, 0 failed)** on 2026-09-19 (Node stack).
Evidence: `docs/security-evidence/` (`trivy-*.txt`, `gitleaks.txt`, `compose-lint.txt`).
Prior-stack snapshot: `docs/security-evidence-python-stack/` + `docs/SECURITY-python-stack.md` (FastAPI stack, preserved before the MERN port — see `docs/MERN-MIGRATION.md`).

## 1. Database decision (spec deviation, recorded per instruction)

Spec §3 asks for a **relational** database. The project uses **MongoDB 7** instead (document/appointment JSON fits the job workflow, flexible schema, persisted `mongodb_data` volume, private-only).
**Decision (reaffirmed at MERN migration): keep MongoDB, do not migrate.** Rationale: a DB engine swap is a data-layer rebuild (schema, queries in `api`/`worker`, `mongo-init.js`, backup/restore drill in Phase 4) — out of scope for hardening or a runtime-language port, and it would invalidate all test evidence twice. The DB remains private (`private` net `internal:true`, no host port), which satisfies the spec's *intent* (private state, §8–§9). The Node port uses the official `mongodb` driver (v6.21.0) against the same collections/document shapes — no data migration was needed. Revisit only if strict relational semantics are mandated; then prefer Postgres as a standalone phase with its own backup/restore proof.

## 2. Audits performed (Node stack)

| # | Check | Method | Result |
|---|---|---|---|
| 1 | Non-root audit | `grep ^USER` in Dockerfiles + `docker inspect` runtime user | 4/4 custom services `USER node` (unprivileged), runtime verified `node`. Gateway `nginx:alpine` runs as root (upstream design, see §5). |
| 2 | Minimal-image audit | Base-image pin check + `curl`/npm presence + `docker images` sizes | All custom: multi-stage `node:22-slim`, no `curl`, **npm toolchain stripped** from runtime (§3-F5). Sizes: api 345MB, worker 339MB, ai/ehr 332MB. Infra: nginx 93MB, redis 58MB, mongo 1.18GB. |
| 3 | `.dockerignore` | Presence check per service | 4/4 present (excludes `node_modules/`, `.git`, `.env`, `environments/`, docs). Carried over from Python phase. |
| 4 | Trivy image scan (HIGH,CRITICAL) | `trivy image` on all 4 custom images | App npm deps: **0 findings** (express 4.22.3, mongodb 6.21.0, ioredis 5.11.1 clean). npm-toolchain CVEs: **fixed to zero** (§3-F5). Debian bookworm OS: 52 HIGH + 4 CRITICAL with **no upstream fix** (see §5). |
| 5 | Gitleaks secret scan | `gitleaks detect` in git mode (`.git` present since P0.1; `--no-git` fallback outside a checkout) | **No leaks found**. Secrets only via env files/placeholders. |
| 6 | Compose lint | `scripts/compose-lint.py` (42 assertions) | **42 pass, 0 fail**, 3 warn (documented exceptions, §5). Sole public port = gateway; `private internal:true`; no `privileged`/host-mode/dangerous `cap_add`. |

## 3. Findings fixed (Phase 2, both stacks)

Python-stack fixes (evidence in `docs/security-evidence-python-stack/`, detail in `docs/SECURITY-python-stack.md`):
1. **F1 — Vulnerable Python deps (Trivy HIGH ×3 → 0).** `fastapi` 0.115.6 → 0.135.0 (starlette 1.6.0).
2. **F2 — Unnecessary `curl` in all custom images.** Removed; healthchecks moved to language-native clients.
3. **F3 — Missing `.dockerignore`.** Added to all 4 services.
4. **F4 — No runtime privilege containment.** `cap_drop: [ALL]` + `no-new-privileges:true` on all 4 custom services (kept through the MERN port). Negative test: `cap_drop ALL` on `queue` broke `redis:7-alpine` (`Permission denied` on `/data`); reverted with comment.

Node-stack fixes (this migration):
5. **F5 — Bundled npm toolchain CVEs (Trivy node-pkg 10 HIGH + 1 CRITICAL → 0).** First Node build showed 11 npm findings, all in `/usr/local/lib/node_modules/npm/` (brace-expansion ×3, tar CRITICAL CVE-2026-59873 + 2 HIGH, pacote, sigstore, picomatch, ip-address) — npm's own bundle inside `node:22-slim`, **not** app dependencies. Fix: multi-stage Dockerfiles (deps installed in `build` stage) + `rm -rf` of `npm/corepack/npx` binaries in the runtime stage. Verified: `which npm npx` → not found, `node --version` OK, healthchecks (node fetch) pass, Trivy node-pkg section gone, only OS totals remain.

## 4. Verification (Node stack, actual runs 2026-09-19)

- `bash scripts/security-scan.sh` → `SECURITY SCAN: PASS` (26/0).
- `bash scripts/smoke.sh` (dev :8080) → SMOKE OK; `workload.py 20` → avg ~16ms, p95 ~22ms, queue drained to 0.
- AI/EHR via gateway: `POST /ai/query` 200 `mock-triage`; AI wrong-key → 401 `invalid AI API key` (verified from inside cluster net); `ehr` ok/slow(200)/error(500)/auth_fail(401)/unavailable(503)/timeout(504) — all correct.
- Isolation: only gateway publishes a host port; direct `:8001` refused; private net `internal:true`.
- Scale `--scale api=2 --scale worker=2`: all healthy, gateway serves.
- Worker failure: stopped workers → backlog 5 → restarted → drained to 0.
- Recreate `down/up`: 70 appointments persisted in Mongo volume.
- Prod-like (:8081): SMOKE OK, AI/EHR OK, dev unaffected.
- One intentional behavior change vs Python: EHR `slow` sleeps 2s not 3s (see `docs/MERN-MIGRATION.md` — 3s sleep vs 3s client timeout is a race Node timers always lose; 2s preserves the demonstrated slow→200 contract).

## 5. Remaining risks (accepted, with mitigation)

- **R1 — Debian bookworm OS vulns (52 HIGH / 4 CRITICAL) with no fix available** (down from 60/5 on the Python snapshot — fresher base + no Python toolchain). `util-linux` family (`affected`, no fixed version), sqlite/perl/zlib (`fix_deferred`/`will_not_fix`). Cannot be patched by us. Mitigated: non-root `node` user, `cap_drop ALL`, `no-new-privileges`, private-only networking, no `curl`/npm/shell tooling in image. Next lever (Phase 3+): digest pinning, rebuild tracking, distroless evaluation.
- **R2 — `gateway` (nginx:alpine) runs as root.** Upstream design (master binds `:80`). Mitigated: official minimal image, config `:ro`, sole published port, no `privileged`.
- **R3 — `db`/`queue` without `cap_drop`.** `mongo` needs chown/dac on init; `redis` entrypoint chowns `/data` (proven experiment, §3-F4). Both on `internal:true`, no host ports.
- **R4 — Credentials in version control. CLOSED:** `environments/dev.env`/`prod.env` are now git-ignored and generated locally by `scripts/setup-env.sh` (live values never committed); only `.env.example` (placeholders) is tracked. Gitleaks-clean. Rule: local-simulation values stay on the host; real secrets via host env/secret store before any shared use.
- **R5 — Images unpinned by digest; `read_only` not enforced.** **CLOSED (digest half) in Phase 3:** all bases pinned by digest — `node:22-slim@sha256:48e4…f0f9` (all 4 Dockerfiles, both stages), `nginx:alpine@sha256:4870…55b2`, `redis:7-alpine@sha256:5207…78bc7`, `mongo:7-jammy@sha256:84c4…55bd0` — and a Trivy `--exit-code`-style gate added (`scripts/trivy-gate.sh`: app-dep HIGH/CRITICAL block, OS baseline report-only). `security-scan.sh` re-run after pinning → still PASS 26/0. `read_only` remains future work (Phase 4 candidate).
- **R6 — MongoDB image is SSPL (not OSI-approved).** Free local use; swap to Postgres/FerretDB only if strict-OSI licensing is required.
- **R7 — Node images larger than Python ones** (332–345MB vs 221–244MB; node runtime + npm-installed deps). Accepted: still small vs infra images (mongo 1.18GB); multi-stage already applied.

## 6. Evidence index

- `docs/security-evidence/trivy-{api,ai-service,worker,ehr-mock}.txt` — Node-stack reports (npm 0 findings; OS 52H/4C).
- `docs/security-evidence/gitleaks.txt` — `no leaks found`.
- `docs/security-evidence/compose-lint.txt` — 42 pass / 0 fail / 3 warn.
- `docs/security-evidence-python-stack/` + `docs/SECURITY-python-stack.md` — pre-migration snapshot.
- `scripts/security-scan.sh` — single entry point (exit 1 on any gate failure).
- `scripts/compose-lint.py` — lint rules.

## 7. Scope guard

Phase 2 only. No Phase 3 pipeline/rollback work started; database engine unchanged (§1); **no React/frontend added** (spec §26 explicitly excludes UIs).

## 8. Phase 3 addendum (2026-09-19 — pipeline gated on this report)
- `scripts/security-scan.sh` is called **as-is** by `scripts/pipeline.sh` (plus a binding
  `scripts/trivy-gate.sh` on newly built images). One robustness fix applied to the
  script itself: the stale `gitleaks.txt` report is deleted *before* scanning, because
  Gitleaks `-v` output embeds matched secret text and a leftover FAIL report would
  re-trip the next scan (found during the seeded-secret block demo — `docs/CICD.md` §7).
  No detection weakened (no allowlists); gate re-verified PASS 26/0 after the fix.
- Full Phase 3 evidence (healthy rollout, security block, rollback): `docs/CICD.md` +
  `docs/pipeline-evidence/`.

## 9. Phase 4 addendum (2026-09-19 — monitoring added, posture re-verified)

- 7 new images (Prometheus, Grafana, Alertmanager, Pushgateway, 3 exporters),
  all version- **and digest-pinned** — R5 stays closed.
- `compose-lint.py` rule refined: `127.0.0.1`-bound admin ports (Grafana) are a
  warn-only documented exception; any other non-gateway published port still
  fails. Lint: **70 pass / 0 fail / 4 warn**; `security-scan.sh` re-verified
  **PASS 26/0** after all Phase 4 changes (final regression: pipeline
  `p4-final-01`, exit 0).
- Two Docker behaviors recorded in `docs/SPOF.md` §4b: `internal:true` networks
  silently drop published ports (hence dual-net Grafana/nginx-exporter, same
  pattern as `api`); Gitleaks `-v` self-contamination (Phase 3 fix retained).
- No new secrets model: Grafana admin creds are placeholder env vars like the
  rest (R4); Gitleaks-clean including all new files and evidence logs.

## 10. Remediation addendum (P0–P1, 2026-09-19)

- Gate count grew **26 → 32 passed** when `alert-logger` (P1.4, 15th service)
  joined all five per-service loops (non-root, minimal-image, `.dockerignore`,
  Trivy report, runtime user). No check was removed or weakened; historical
  26/0 references above describe the 4-service gate and remain accurate
  for their date.
- Gitleaks runs in **git mode** since P0.1 (was `--no-git` before git history
  existed); clean, including `terraform/*.tfvars` placeholders (R4 posture)
  and the git-ignored `gateway/tls/` keypair, which never enters history.
- `compose-lint.py` passing (currently 81 pass / 0 fail / 4 warn: 77 + 4 new
  read-only-root-FS assertions for the Node services; the 32/0 RESULT line
  counts gates).
- Gitleaks `curl-auth-user` finding on `scripts/rotate-secrets.sh` (first seen
  in commit `c744877`, git-mode history scan): **false positive** — the match
  is a shell *variable reference* (`"$ADB_USER"`, long `--username` form since
  the round-2 fix), never a literal credential. Allowlisted by path+rule in
  `.gitleaks.toml` (wired via `--config` in `security-scan.sh`); generic
   high-entropy rules remain active on the file. Post-fix gate: **32/0 PASS**.
- Exporter least-privilege (round-2): `mongodb-exporter` now authenticates as
  `monitor_user` (`clusterMonitor` on `admin`) instead of the root credential
  (`db/mongo-init.js` + `scripts/create-db-users.sh` + compose URI). Verified
  live 2026-09-19: `up{job="mongodb"}==1`, `mongodb_up==1`, and a negative
  probe (`find` on `healthcare.appointments` as `monitor_user`) is refused
  with `not authorized`. Root remains only in `db` init + rotation scripts.
- Read-only root filesystem (round-2): `api`, `worker`, `ai-service`,
  `ehr-mock` run with `read_only: true` + writable `tmpfs` on `/tmp`.
  Evaluated live before enforcing (throwaway container: `/health` OK,
  `POST /appointments` 200, `touch /app` refused, `touch /tmp` OK), then
  rolled to both envs (all healthy, `SMOKE OK`) and asserted by 4 new
  `compose-lint.py` checks (81 pass total). Base images stay `node:22-slim`
  pinned by digest; distroless noted as future work with no stub-status
  regression risk taken now.
