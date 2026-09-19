# Security Report — Phase 2: Hardening + Security Validation

Date: 2026-09-19 · Stack: Ubuntu/Mint + Docker · Tools (FOSS): Trivy 0.74.0, Gitleaks 8.30.1 (both via Docker images), custom `scripts/compose-lint.py` (stdlib only)
One-command gate: `bash scripts/security-scan.sh` → **PASS (26 passed, 0 failed)** on 2026-09-19.
Evidence: `docs/security-evidence/` (`trivy-*.txt`, `gitleaks.txt`, `compose-lint.txt`).

## 1. Database decision (spec deviation, recorded per instruction)

Spec §3 asks for a **relational** database. Phase 1 implemented **MongoDB 7** instead (document/appointment JSON fits the job workflow, flexible schema, persisted `mongodb_data` volume, private-only).
**Phase 2 decision: keep MongoDB, do not migrate.** Rationale: a DB engine swap is a data-layer rebuild (schema, queries in `api`/`worker`, `mongo-init.js`, backup/restore drill in Phase 4) — out of scope for a hardening phase and would invalidate Phase 1 test evidence. The DB remains private (`private` net `internal:true`, no host port) which satisfies the spec's *intent* (private state, §8–§9). Revisit only if strict relational semantics are mandated; then prefer Postgres + FerretDB-style migration as a standalone phase with its own backup/restore proof.

## 2. Audits performed

| # | Check | Method | Result |
|---|---|---|---|
| 1 | Non-root audit | `grep ^USER` in Dockerfiles + `docker inspect` runtime user | 4/4 custom services `USER appuser` (uid 10000), runtime verified `appuser`. Gateway `nginx:alpine` runs as root (upstream design, see §5). |
| 2 | Minimal-image audit | Base-image pin check + `curl` presence + `docker images` sizes | All custom: `python:3.12-slim-bookworm`, no `curl`. Sizes: api 244MB, worker 226MB, ai/ehr 221MB (down from 253/235/231MB pre-fix). Infra: nginx 93MB, redis 58MB, mongo 1.18GB. |
| 3 | `.dockerignore` | Presence check per service | 4/4 present (excludes `__pycache__`, `.git`, `.env`, `environments/`, docs). **Was missing pre-fix.** |
| 4 | Trivy image scan (HIGH,CRITICAL) | `trivy image` on all 4 custom images | Python deps: **0 findings** (fixed, §3). Debian bookworm OS: 60 HIGH + 5 CRITICAL with **no upstream fix** (see §5). |
| 5 | Gitleaks secret scan | `gitleaks detect --no-git` (repo has no `.git`) | **No leaks found** (~313KB scanned). Secrets only via env files/placeholders. |
| 6 | Compose lint | `scripts/compose-lint.py` (42 assertions) | **42 pass, 0 fail**, 3 warn (documented exceptions, §5). Sole public port = gateway; `private internal:true`; no `privileged`/host-mode/dangerous `cap_add`. |

## 3. Findings fixed in Phase 2 (≥1 required — 4 delivered)

1. **F1 — Vulnerable Python deps (Trivy HIGH ×3, remediated to zero).** Baseline `fastapi==0.115.6` pulled `starlette 0.41.3` with CVE-2025-62727 (Range-header DoS, fixed 0.49.1), CVE-2026-48818 (StaticFiles UNC SSRF, fixed 1.1.0), CVE-2026-54283 (form-limit DoS, fixed 1.3.1). Fix: bumped `fastapi` 0.115.6 → 0.124.4 (starlette 0.50.0, fixed 1 of 3) → **0.135.0 (starlette 1.6.0, all 3 fixed)** in `api`, `ai-service`, `ehr-mock`. Verified: post-fix Trivy shows `starlette-1.6.0 … 0 findings`; `smoke.sh` + AI/EHR-via-gateway + workload-10 all pass on the new stack.
2. **F2 — Unnecessary `curl` in all custom images (attack surface).** Healthchecks use `python urllib`, so `apt-get install curl` served no runtime purpose. Fix: removed `curl`/apt layer from all 4 Dockerfiles; runtime `which curl` → NOT-FOUND on all 4; images shrank 9–10MB each.
3. **F3 — Missing `.dockerignore` (build-context hygiene).** Pre-fix: none existed; `docker build` could ship `.env`/`environments/`/`.git` into context. Fix: added identical `.dockerignore` to all 4 services.
4. **F4 — No runtime privilege containment.** Pre-fix: no `cap_drop`/`security_opt` anywhere. Fix: `cap_drop: [ALL]` + `security_opt: [no-new-privileges:true]` on `api`, `ai-service`, `worker`, `ehr-mock` (verified via `docker inspect`: `CapDrop=[ALL]`, `SecurityOpt=no-new-privileges:true`, all healthy). Negative test recorded: applying `cap_drop ALL` to `queue` broke `redis:7-alpine` entrypoint (`find: ./appendonlydir: Permission denied` — needs chown/setuid on `/data`); reverted with comment in `docker-compose.yml`.

## 4. Verification (post-fix, actual runs 2026-09-19)

- `bash scripts/security-scan.sh` → `SECURITY SCAN: PASS` (26/0). Re-runnable; Trivy reports saved per image.
- `bash scripts/smoke.sh` (dev :8080) → SMOKE OK (health, ready db+queue ok, create+list, metrics queue 0).
- `python3 scripts/workload.py http://localhost:8080 10` → avg ~15ms, queue drained 9→0.
- AI/EHR via gateway: `POST /ai/query` 200 `mock-triage`, `GET /ehr/status?mode=ok` 200, `?mode=error` 500 retryable — all OK on fastapi 0.135.0.
- `docker compose config` clean for dev and prod-like envs.

## 5. Remaining risks (accepted, with mitigation)

- **R1 — Debian bookworm OS vulns (60 HIGH / 5 CRITICAL) with no fix available.** Top: `util-linux` family (TOCTOU/nsenter/mount-hook, status `affected`, no fixed version), `libsqlite3-0` CVE-2025-7458 CRITICAL, `perl-base` CVE-2026-13221 CRITICAL, `zlib1g` CVE-2023-45853 CRITICAL (`will_not_fix` in bookworm), `gzip`/`libacl1` (`fix_deferred`). These ship with `python:3.12-slim-bookworm` and cannot be patched by us. Mitigations applied: non-root, `cap_drop ALL`, `no-new-privileges`, private-only networking, no `curl`/shell tooling in image. Next lever (Phase 3+): track `python:3.12-slim` rebuilds / distroless base.
- **R2 — `gateway` (nginx:alpine) runs as root.** Upstream design: master binds `:80` then drops workers. Hardening it (non-root user or `cap_drop`) requires re-porting to 8080 + config change; deferred to avoid ingress churn in a hardening phase. Mitigated by: official minimal image (93MB), config mounted `:ro`, sole published port, no `privileged`.
- **R3 — `db`/`queue` without `cap_drop`.** `mongo:7-jammy` needs chown/dac on init; `redis:7-alpine` entrypoint chowns `/data` (proven by failed experiment, §3-F4). Both isolated on `internal:true` net with no host ports.
- **R4 — Placeholder credentials committed (`dev.env`/`prod.env`).** Values are non-production (`dev_only_change_me`) and Gitleaks-clean, but they live in the repo. Rule: never put real secrets in env files; inject via host env/secret store before any shared use (already warned in README + `.env.example`).
- **R5 — Images unpinned by digest; `read_only`/`userns`/seccomp not enforced.** Compose-level `read_only:true` was skipped (uvicorn bytecode/`/tmp` writes risk). Candidates for Phase 3 pipeline gates (digest pinning + Trivy `--exit-code` gate).
- **R6 — MongoDB image is SSPL (not OSI-approved).** Free to run locally; noted in ARCHITECTURE.md. Swap to Postgres/FerretDB only if strict-OSI licensing is required.

## 6. Evidence index

- `docs/security-evidence/trivy-{api,ai-service,worker,ehr-mock}.txt` — full Trivy reports (post-fix: Python 0, Debian 60H/5C).
- `docs/security-evidence/gitleaks.txt` — `no leaks found`.
- `docs/security-evidence/compose-lint.txt` — 42 pass / 0 fail / 3 warn.
- `scripts/security-scan.sh` — single entry point (exit 1 on any gate failure; Trivy reported, non-blocking for unfixed OS CVEs).
- `scripts/compose-lint.py` — lint rules (§2-#6).

## 7. Scope guard

Phase 2 only. No Phase 3 pipeline/rollback work started; database engine unchanged (§1). Proposed Node.js/Express (MERN) port is a separate, not-yet-approved plan — no service code was rewritten for it in this phase.
