# Cost Awareness — Local Measurements + Cloud Mapping (PRD §22)

Local stack is €0 by construction (all FOSS/self-hosted). The production
question is what each replica and each retained byte *would* cost — measured
below, then mapped to AWS list prices (eu-central-1, Sep 2026, on-demand).

## Measured (this host, `RESILIENCE.md §5` + current)

| Component | Idle RAM | Disk image | Buys what |
|---|---|---|---|
| api (×1) | ~49 MB | 345 MB | stateless enqueue (~7–11 ms avg) |
| worker (×1) | ~35–39 MB | 339 MB | ~3 jobs/s drain (linear to 6.7/s at ×2) |
| queue (redis) | ~7 MB | 58 MB | burst buffer (302 jobs banked without API slowdown) |
| db (mongo) | ~99 MB | 1.18 GB | all persistent state |
| prometheus | ~44 MB | 440 MB | 7d/1GB retention (bounded) |
| grafana | ~75 MB | 873 MB | 19-panel dashboard (dominant disk cost) |
| exporters ×3 + pushgateway + alertmanager | <30 MB | ~150 MB | per-component telemetry |

Dev total idles <400 MB; monitoring adds ~150 MB RAM but ~1.5 GB disk.
Binding host constraint is **disk** (94%), not RAM — prune superseded tags
first (`backup-mongo.sh` keep-5 caps regrowth).

## Cloud mapping (monthly, on-demand, single-AZ simulation → multi-AZ prod)

| Local | Cloud equivalent | Idle/mo | Loaded (×3 workers) | Notes |
|---|---|---|---|---|
| gateway (nginx) | ALB + ACM cert | ~$25 | ~$25 + LCU | TLS termination moves to ACM; rate-limit → WAF rule |
| api ×1 (0.5 CPU/512M) | ECS Fargate 0.5vCPU/1GB | ~$20 | ~$60 (×3) | HPA on `api_queue_depth` / CPU replaces `autoscale.sh` |
| worker ×1 | Fargate 0.5vCPU/1GB (spot-eligible) | ~$20 (~$6 spot) | ~$60 (~$18) | The only knob that scales with load — batch/async is spot-friendly |
| queue (redis AOF) | ElastiCache t4g.micro (Multi-AZ) | ~$15 | ~$15 | Single-instance + AOF is the accepted SPOF; Multi-AZ removes it |
| db (mongo volume) | DocumentDB db.t3.medium + storage/PITR | ~$70 + $10 | same | PITR replaces dump-cron RPO (24h → minutes) |
| prometheus/grafana | AMP + AMG (or self-hosted) | ~$30 | ~$30 | Retention to S3/GCS archival replaces 7d/1GB local cap |
| logs | CloudWatch/S3 archival | ~$5 | ~$10 | `collect-logs.sh` bundle → log-group retention policy |
| **Total** | | **~$195** | **~$210** | Workers dominate marginal cost; observability dominates fixed disk |

## Trade-off statement

Reliability costs money only where it buys recovery: multi-AZ queue/DB
(~$85) removes the two data-plane SPOFs; extra workers are linear and
spot-eligible (~$6 each). Everything else (TLS, HPA, paging, PITR) is
configuration, not capacity — the architecture already exposes the dials
(`docker-compose.prod.yml` limits, `autoscale.sh` thresholds, retention caps).
