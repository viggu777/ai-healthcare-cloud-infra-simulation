# 3 Videos Shoot Guide — Linux Mint 21.3 + Chrome — Small Videos Only

Target: 3 short videos, each 4-6 min. Total <16 min.
Record with SimpleScreenRecorder (already installed on your Mint) + Chrome.

## 0. One-time Mint setup (2 min)

```bash
# recorder is already installed on your machine:
which simplescreenrecorder google-chrome
# if mic not detected: install pavucontrol
sudo apt update && sudo apt install -y pavucontrol

# terminal readable on video:
# Terminal > Edit > Preferences > Text > Font size 14, Window 140x35
# Chrome: Settings > Appearance > Font size Large, close extra tabs
```

Recording profile in SimpleScreenRecorder:
- Input: Record full screen 1920x1080, 30 fps
- Audio: Backend PulseAudio, Source your mic (test bar moves)
- Output: MP4, file `~/Videos/01-sim-env.mp4`, `02-cicd.mp4`, `03-final.mp4`

Chrome open command for all videos (Mint):

```bash
google-chrome-stable --new-window \
  http://localhost:8080/health \
  http://127.0.0.1:3000 \
  2>/dev/null &
```

## 1. Passwords CHANGED — use these, do NOT cat env files on video

Your repo now uses demo passwords (not the old `dev_only_change_me` in docs).
Docs `DEMO.md:38` still says old password — ignore it, use this table:

| Where | Dev | Prod-like |
|---|---|---|
| Gateway | `http://localhost:8080` | `http://localhost:8081` |
| Grafana URL | `http://127.0.0.1:3000` | `http://127.0.0.1:3001` |
| Grafana login | `admin / 12345678` | `admin / 12345678` |
| MONGO_PASSWORD | `12345678` | `12345678` |
| AI_API_KEY | `kmvk777` | `kmvk777` |
| APP_VERSION | `0.1.0-dev` | `0.1.0` |

Rules for video:
1. NEVER run `cat environments/dev.env` or `cat prod.env` on record — it shows secrets.
2. If you must prove secrets not hardcoded, run this safe version (shows length, not value):

```bash
grep -E '^(GATEWAY_PORT|GRAFANA_PORT|APP_VERSION|MONGO_DB|WORKER_CONCURRENCY)' environments/dev.env
echo "MONGO_PASSWORD length: $(grep MONGO_PASSWORD environments/dev.env | cut -d= -f2 | wc -c)"
```

3. Code is Node.js 22 + Express, MongoDB 7, Redis 7 — say that line once per video.

## 2. Common start for every video (30 sec)

```bash
cd /home/viggu/Documents/ai-healthcare-cloud-infra-simulation
export DOCKER_CONFIG=/tmp/docker-nocreds
D="docker compose --env-file environments/dev.env"
```

Fix-before-record (your stack right now has `queue exited`, `worker unhealthy`, `ready:false`):

```bash
docker compose --env-file environments/dev.env up -d queue worker api
sleep 20
curl -s http://localhost:8080/ready; echo
# want: {"ready":true,"checks":{"db":"ok","queue":"ok"}}
```

Voice line: "I fix any exited container before recording, ready must be true."

Check baseline (do off-camera, then show result in video):

```bash
docker compose --env-file environments/dev.env ps --format "table {{.Service}}\t{{.Status}}"
# want 15 lines: 7 app + 8 observability, all Up healthy except 3 exporters show Up
```

7 app = gateway, api, ai-service, worker, queue, db, ehr-mock.
8 observability = prometheus, grafana, alertmanager, pushgateway, redis-exporter, mongodb-exporter, nginx-exporter, alert-logger.

## 3. VIDEO 1 — Simulation Environment (4 min)

File: `01-sim-env.mp4`. Goal: it runs, one door, recreates.

Shot 1 — 0:00 architecture (30 sec). Open `docs/TARGET_ARCHITECTURE.md §2` in VS Code.
Say: "I own infrastructure, not hospital app. Fake api, ai, worker, redis queue, mongo file cabinet, ehr outside office. Only gateway is public."

Shot 2 — 0:30 sole door (40 sec). Run:

```bash
docker ps --format '{{.Names}} {{.Ports}}' | grep gateway
curl -s http://localhost:8080/health; echo
curl -m 3 http://localhost:8001/health || echo "private blocked - good"
```

Say: "Only gateway has host port 8080. You see api ok via gateway. Direct 8001 refused, that means ai-service is private. This is public versus private."

Shot 3 — 1:10 normal run (60 sec). Run:

```bash
bash scripts/smoke.sh
```

You will see: gateway health, ready true, create appointment returns job_id, list 3, metrics, SMOKE OK.
Say: "Smoke creates one patient booking via gateway only. Queued means reception gave token, clerk will do slow work later."

Shot 4 — 2:10 load (50 sec). Run:

```bash
python3 scripts/workload.py http://localhost:8080 10
```

You will see: enqueued 10 avg 6ms p95 8ms, queue_depth 10 down to 0.
Say: "Ten patients at once. Api stays fast 6 millisecond. Queue grows then drains to zero. That is worker clearing."

Shot 5 — 3:00 dashboard (40 sec). In Chrome open `http://127.0.0.1:3000`, login `admin / 12345678`, open dashboard `AI Healthcare Sim — Overview`.
Say: "Same queue, api, worker, db, ehr graphs operator sees. No need to open each container."

Shot 6 — 3:40 recreate (30 sec). Run:

```bash
docker compose --env-file environments/dev.env down
docker compose --env-file environments/dev.env up -d
sleep 20; bash scripts/smoke.sh
```

Say: "Down and up recreates same hospital from code. Data stays in mongo volume. That is infrastructure as code."

Stop recording.

## 4. VIDEO 2 — CI/CD Demonstration (5 min)

File: `02-cicd.mp4`. Goal: pipeline blocks bad, rolls back broken. Do NOT run full 10-min pipeline live — run short + show logs.

Shot 1 — 0:00 stages (40 sec). Show `.github/workflows/pipeline.yml` top 30 lines + run:

```bash
bash scripts/pipeline.sh --help
bash scripts/security-scan.sh 2>&1 | tail -5
```

You will see: RESULT PASS, stages lint unit audit security build trivy-gate deploy dev health-gate workload promote.
Say: "Same stages locally and in GitHub Actions. Security is gate, not last manual check."

Shot 2 — 0:40 healthy short run (2 min). Run small tag live:

```bash
bash scripts/pipeline.sh --tag video-demo-01 --workload 5 --health-timeout 60
```

You will see: lint-ok 6, unit pass 6 fail 0, security PASS, trivy GATE PASS, build 4 images, deploy dev, READY, SMOKE OK, WORKLOAD DONE, promote prod-like 8081, PASS.
Say: "Healthy version goes dev 8080 then prod-like 8081 only after ready true. Tag is version."

If time short, stop after dev PASS with Ctrl+C and say prod-like same — but better let it finish, it is ~4 min with workload 5.

Shot 3 — 2:40 security block (60 sec). Do NOT re-seed secret live. Show old log:

```bash
cat docs/pipeline-evidence/pipeline-p3-demo-blocked-secret.log | grep -E "RESULT|BLOCKED|FAIL|healthy1" | head -10
curl -s http://localhost:8080/health; echo
```

You will see: 25 passed 1 failed, BLOCKED at security, dev still serves healthy1.
Say: "Fake private key blocked before build. Running version untouched. That is DevSecOps."

Shot 4 — 3:40 rollback (60 sec). Show old log:

```bash
cat docs/pipeline-evidence/pipeline-p3-demo-broken-ready.log | grep -E "TIMEOUT|ROLLBACK|RESULT|ready" | head -12
```

You will see: health gate TIMEOUT 120s, ROLLBACK restoring previous tag, previous version serving, prod-like never touched.
Say: "Broken ready false never replaces healthy. Rollback restores old tag automatically."

Shot 5 — 4:40 trace (20 sec). Run:

```bash
ls -lh docs/pipeline-evidence/ | tail -5
```

Say: "Every run saves log, who what version checks pass fail, that is audit."

Stop recording.

## 5. VIDEO 3 — Final Walkthrough / Demo (5 min)

File: `03-final.mp4`. Goal: PRD §32 story + 1 failure + tradeoffs.

Shot 1 — 0:00 normal (30 sec). `bash scripts/smoke.sh` → SMOKE OK.
Say: "Start normal, all healthy."

Shot 2 — 0:30 boundaries (30 sec). `docker ps --format '{{.Names}} {{.Ports}}'` + `python3 scripts/compose-lint.py 2>&1 | tail -3`.
Say: "One public door, lint proves no public db queue."

Shot 3 — 1:00 worker fail fast version (2 min). Do NOT wait 2.5 min for alerts in short video — show queue behavior + API query:

```bash
docker compose --env-file environments/dev.env stop worker
python3 scripts/workload.py http://localhost:8080 15
# you see queue_depth=15 frozen, api still fast 6ms
curl -s http://localhost:8080/metrics | grep queue_depth
docker compose --env-file environments/dev.env up -d worker
sleep 25
curl -s http://localhost:8080/metrics | grep queue_depth
bash scripts/smoke.sh
```

Say: "Worker stopped like crash. Fifteen jobs stay in redis, none lost, api still fast. Restart drains to zero in 20 seconds. In long incident WorkerDown fires 1.5 min, QueueBacklog 2.5 min, details in docs INCIDENTS."
If you want alert on camera, open Grafana Firing alerts panel, but skip waiting.

Shot 4 — 3:00 EHR fail (40 sec). Run:

```bash
curl -s "http://localhost:8080/ehr/status?mode=error"; echo
curl -s "http://localhost:8080/ehr/status?mode=auth_fail"; echo
```

You will see: 500 retryable true, 401 retryable false.
Say: "Outside office error retries 3 times with backoff, auth fail never retries, breaker opens after 5 fails. Worker never crashes."

Shot 5 — 3:40 tradeoffs (60 sec). Show `docs/TARGET_ARCHITECTURE.md §13` + `§14` headings, speak, no commands:
Say: "Mongo not relational by documented deviation, role same private persisted backed up. Single host no IAM no autoscaler, Nginx static DNS so scale workers linear 3 per sec, not api. Free only, disk is limit. No frontend real AI real EHR real cloud, out of scope."

Stop recording.

## 6. Upload to Drive (Mint + Chrome)

```bash
ls -lh ~/Videos/01-sim-env.mp4 ~/Videos/02-cicd.mp4 ~/Videos/03-final.mp4
# each <200MB ideal. If bigger, re-encode:
# sudo apt install -y ffmpeg
# ffmpeg -i ~/Videos/01-sim-env.mp4 -vcodec libx264 -crf 28 ~/Videos/01-sim-env-small.mp4
```

In Chrome:
1. drive.google.com → New → File upload → select 3 mp4
2. For each → Right click Share → General access → Anyone with the link can view → Copy link
3. Paste into form fields Simulation Environment Video Link, CI/CD Demonstration Video Link, Demo Walkthrough Link → click Attach
4. Test in incognito `Ctrl+Shift+N` — must play without login.

Checklist before Attach:
- [ ] voice audible all 3
- [ ] 8080 health READY true visible
- [ ] Grafana login 12345678 works, dashboard visible
- [ ] no `cat *.env` full secret visible (pause and blur if needed in SimpleScreenRecorder edit)
- [ ] pipeline PASS + BLOCKED + ROLLBACK all shown via live + logs
- [ ] links are Anyone with link
