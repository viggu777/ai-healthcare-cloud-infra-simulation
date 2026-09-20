/* Background worker — consumes Redis queue, updates MongoDB, calls EHR mock.
 * Observable: queue depth, processing latency, failed jobs, retries, restarts.
 * Fail modes via WORKER_FAIL_MODE: off|slow|error|crash
 * P1.2 resilience: EHR calls run bounded retries with exponential backoff
 * (EHR_MAX_ATTEMPTS/EHR_BACKOFF_BASE_MS/EHR_BACKOFF_MAX_MS) behind a
 * consecutive-failure circuit breaker (BREAKER_THRESHOLD/BREAKER_COOLDOWN_MS);
 * EHR 401 lands in terminal `failed_auth` (never retried). Exception-path
 * requeue also backs off (retry while attempts<3, else jobs:dead list).
 * /health contract on :8003.
 */
'use strict';

const http = require('http');
const { MongoClient } = require('mongodb');
const Redis = require('ioredis');

const MONGODB_URI = process.env.MONGODB_URI || '';
const MONGO_DB = process.env.MONGO_DB || 'healthcare';
const REDIS_URL = process.env.REDIS_URL || 'redis://queue:6379/0';
const EHR_URL = process.env.EHR_URL || 'http://ehr-mock:8002';
const FAIL_MODE = process.env.WORKER_FAIL_MODE || 'off';
const CONCURRENCY = parseInt(process.env.WORKER_CONCURRENCY || '2', 10);
// P1.2 resilience dials (bounded retry with exponential backoff + circuit breaker).
const EHR_MAX_ATTEMPTS = parseInt(process.env.EHR_MAX_ATTEMPTS || '3', 10);
const EHR_BACKOFF_BASE_MS = parseInt(process.env.EHR_BACKOFF_BASE_MS || '1000', 10);
const EHR_BACKOFF_MAX_MS = parseInt(process.env.EHR_BACKOFF_MAX_MS || '8000', 10);
const BREAKER_THRESHOLD = parseInt(process.env.BREAKER_THRESHOLD || '5', 10);
const BREAKER_COOLDOWN_MS = parseInt(process.env.BREAKER_COOLDOWN_MS || '15000', 10);
const PORT = 8003;

const redis = new Redis(REDIS_URL, { connectTimeout: 5000, maxRetriesPerRequest: null });
redis.on('error', (e) => console.error('[worker] redis error:', e.message));

const mongo = MONGODB_URI
  ? new MongoClient(MONGODB_URI, { serverSelectionTimeoutMS: 5000 })
  : null;
if (mongo) mongo.connect().catch((e) => console.error('[worker] mongo connect error:', e.message));

let processedTotal = 0;
let failedTotal = 0;
let retriesTotal = 0; // Phase 4: requeued jobs (attempts<3 path)
let deadTotal = 0; // Phase 4: jobs moved to jobs:dead after exhausting retries
let latencyMsTotal = 0;
// Phase 4: EHR call outcome mix as observed by the worker (drives the
// Grafana "EHR outcome mix" panel + EHROutage alert).
const ehrOutcomes = { ok: 0, error_5xx: 0, auth_401: 0, unavailable_503: 0, timeout: 0, breaker_open: 0, other: 0 };
// P1.2: consecutive-failure circuit breaker around the EHR dependency.
// closed = calls flow; open = EHR skipped fast (jobs degrade without
// hammering); half-open = one probe call after the cooldown decides.
let breakerState = 'closed';
let consecutiveFailures = 0;
let breakerOpenedAt = 0;
let breakerTripsTotal = 0;
const startedAt = Date.now();

// Bounded exponential backoff: base * 2^(attempt-1), capped at max.
const backoffMs = (attempt /* 1-based */) =>
  Math.min(EHR_BACKOFF_BASE_MS * (2 ** (attempt - 1)), EHR_BACKOFF_MAX_MS);

function mdb() {
  return mongo.db(MONGO_DB);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function queueDepth() {
  try {
    return await redis.llen('jobs');
  } catch {
    return -1;
  }
}

// Dependency-aware readiness (H5 fix): ping MongoDB + Redis live, like api
// /ready. Returns {db, queue} so /health can report degraded/503 instead of
// a hardcoded ok. Null-safe: missing clients report fail, never throw.
// Bounded: each check races a 3s timeout so a hung dependency fails fast
// (ioredis queues commands while disconnected; without the race /health
// would hang instead of reporting degraded). Fits the 5s container
// healthcheck timeout.
const withTimeout = (ms, what) =>
  new Promise((_, rej) => setTimeout(() => rej(new Error(`${what} timeout`)), ms));

async function depChecks() {
  const checks = {};
  try {
    if (!mongo) throw new Error('MONGODB_URI not set');
    try {
      await Promise.race([mongo.db('admin').command({ ping: 1 }), withTimeout(3000, 'mongo')]);
    } catch {
      await mongo.connect(); // self-heal closed topology (same boot-race as api /ready)
      await Promise.race([mongo.db('admin').command({ ping: 1 }), withTimeout(3000, 'mongo')]);
    }
    checks.db = 'ok';
  } catch (e) {
    checks.db = `fail: ${e.message}`;
  }
  try {
    await Promise.race([redis.ping(), withTimeout(3000, 'redis')]);
    checks.queue = 'ok';
  } catch (e) {
    checks.queue = `fail: ${e.message}`;
  }
  return checks;
}

// Health endpoint (bare http — no web framework needed in the worker).
// /health is dependency-aware (200 ready / 503 degraded); /metrics keeps the
// legacy always-200 JSON shape (scrapers use /metrics/prom for Prometheus text).
const server = http.createServer(async (req, res) => {
  if (req.method === 'GET' && req.url === '/health') {
    const checks = await depChecks();
    const ready = Object.values(checks).every((v) => v === 'ok');
    const qd = await queueDepth();
    const body = JSON.stringify({
      status: ready ? 'ok' : 'degraded',
      service: 'worker',
      ready,
      checks,
      queue_depth: qd,
      processed_total: processedTotal,
      failed_total: failedTotal,
      avg_latency_ms: processedTotal ? Math.round((latencyMsTotal / processedTotal) * 100) / 100 : 0,
      uptime_s: Math.round((Date.now() - startedAt) / 100) / 10,
      fail_mode: FAIL_MODE,
      breaker_state: breakerState,
      consecutive_ehr_failures: consecutiveFailures,
    });
    res.writeHead(ready ? 200 : 503, { 'Content-Type': 'application/json' });
    res.end(body);
  } else if (req.method === 'GET' && req.url === '/metrics') {
    const qd = await queueDepth();
    const body = JSON.stringify({
      status: 'ok',
      service: 'worker',
      queue_depth: qd,
      processed_total: processedTotal,
      failed_total: failedTotal,
      avg_latency_ms: processedTotal ? Math.round((latencyMsTotal / processedTotal) * 100) / 100 : 0,
      uptime_s: Math.round((Date.now() - startedAt) / 100) / 10,
      fail_mode: FAIL_MODE,
      breaker_state: breakerState,
      consecutive_ehr_failures: consecutiveFailures,
    });
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(body);
  } else if (req.method === 'GET' && req.url === '/metrics/prom') {
    // Phase 4: Prometheus exposition format (text). JSON /metrics above untouched.
    const qd = await queueDepth();
    const avg = processedTotal ? latencyMsTotal / processedTotal : 0;
    const lines = [
      '# HELP worker_processed_total Jobs completed (EHR ok or degraded).',
      '# TYPE worker_processed_total counter',
      `worker_processed_total ${processedTotal}`,
      '# HELP worker_failed_total Job attempts that raised (before retry bookkeeping).',
      '# TYPE worker_failed_total counter',
      `worker_failed_total ${failedTotal}`,
      '# HELP worker_retries_total Jobs requeued for another attempt.',
      '# TYPE worker_retries_total counter',
      `worker_retries_total ${retriesTotal}`,
      '# HELP worker_dead_letter_total Jobs moved to jobs:dead after exhausting retries.',
      '# TYPE worker_dead_letter_total counter',
      `worker_dead_letter_total ${deadTotal}`,
      '# HELP worker_latency_ms_sum Sum of job processing latency (ms).',
      '# TYPE worker_latency_ms_sum counter',
      `worker_latency_ms_sum ${Math.round(latencyMsTotal * 100) / 100}`,
      '# HELP worker_avg_latency_ms Mean job processing latency (ms).',
      '# TYPE worker_avg_latency_ms gauge',
      `worker_avg_latency_ms ${Math.round(avg * 100) / 100}`,
      '# HELP worker_queue_depth Current Redis jobs-list depth (-1 = unreachable).',
      '# TYPE worker_queue_depth gauge',
      `worker_queue_depth ${qd}`,
      '# HELP worker_uptime_seconds Process uptime.',
      '# TYPE worker_uptime_seconds gauge',
      `worker_uptime_seconds ${Math.round((Date.now() - startedAt) / 100) / 10}`,
      '# HELP worker_ehr_outcomes_total EHR call outcomes by result label.',
      '# TYPE worker_ehr_outcomes_total counter',
      ...Object.entries(ehrOutcomes).map(([r, n]) => `worker_ehr_outcomes_total{result="${r}"} ${n}`),
      '# HELP worker_fail_mode_info Active WORKER_FAIL_MODE (label: mode). Always 1.',
      '# TYPE worker_fail_mode_info gauge',
      `worker_fail_mode_info{mode="${FAIL_MODE}"} 1`,
      '# HELP worker_circuit_breaker_state EHR breaker: 0=closed 1=open 2=half-open.',
      '# TYPE worker_circuit_breaker_state gauge',
      `worker_circuit_breaker_state ${breakerState === 'closed' ? 0 : breakerState === 'open' ? 1 : 2}`,
      '# HELP worker_circuit_breaker_trips_total Times the breaker opened.',
      '# TYPE worker_circuit_breaker_trips_total counter',
      `worker_circuit_breaker_trips_total ${breakerTripsTotal}`,
    ];
    res.writeHead(200, { 'Content-Type': 'text/plain; version=0.0.4' });
    res.end(`${lines.join('\n')}\n`);
  } else {
    res.writeHead(404);
    res.end();
  }
});

async function processOne(item) {
  const t0 = Date.now();
  const jobId = item.job_id;
  const apptId = item.appointment_id;
  // Self-heal a closed topology (same boot-race as api /ready: DB users may
  // have been synced after first boot). connect() is a no-op when healthy.
  try { await mongo.connect(); } catch { /* per-op try/catch below reports */ }
  const db = mdb();
  try {
    await db.collection('jobs').updateOne(
      { _id: jobId },
      { $set: { status: 'processing', updatedAt: new Date() }, $inc: { attempts: 1 } },
    );
    if (FAIL_MODE === 'crash') throw new Error('injected crash');
    if (FAIL_MODE === 'slow') await sleep(4000);
    else if (FAIL_MODE === 'error') throw new Error('injected error');
    else await sleep(300); // normal work
    // P1.2: EHR call with bounded retry (exponential backoff) + circuit breaker.
    // Outcomes: 'ok' | 'degraded' (retryables exhausted or breaker open) |
    // 'failed_auth' (401 — non-retryable terminal, never requeued/retried).
    let ehrResult = 'degraded';
    if (breakerState === 'open') {
      if (Date.now() - breakerOpenedAt >= BREAKER_COOLDOWN_MS) {
        breakerState = 'half-open';
        console.warn('[worker] circuit breaker half-open: probing EHR once');
      } else {
        ehrOutcomes.breaker_open += 1;
      }
    }
    if (breakerState !== 'open') {
      const probing = breakerState === 'half-open';
      const maxTries = probing ? 1 : EHR_MAX_ATTEMPTS;
      for (let attempt = 1; attempt <= maxTries; attempt += 1) {
        let status = null;
        try {
          const resp = await fetch(`${EHR_URL}/record/${apptId}`, { signal: AbortSignal.timeout(3000) });
          status = resp.status;
        } catch (e) {
          status = 'timeout';
          console.warn(`EHR call failed for ${jobId} (attempt ${attempt}/${maxTries}): ${e.message}`);
        }
        if (status === 200) {
          ehrOutcomes.ok += 1;
          ehrResult = 'ok';
          consecutiveFailures = 0;
          if (probing) {
            breakerState = 'closed';
            console.warn('[worker] circuit breaker CLOSED (probe succeeded)');
          }
          break;
        }
        if (status === 401) {
          // Non-retryable: bad credential/config. Terminal, no retry, no breaker count.
          ehrOutcomes.auth_401 += 1;
          ehrResult = 'failed_auth';
          console.warn(`[worker] EHR 401 for ${jobId}: marking failed_auth (terminal, no retry)`);
          break;
        }
        if (status === 500) ehrOutcomes.error_5xx += 1;
        else if (status === 503) ehrOutcomes.unavailable_503 += 1;
        else if (status !== 'timeout') ehrOutcomes.other += 1;
        else ehrOutcomes.timeout += 1;
        consecutiveFailures += 1;
        if (probing || consecutiveFailures >= BREAKER_THRESHOLD) {
          breakerState = 'open';
          breakerOpenedAt = Date.now();
          breakerTripsTotal += 1;
          console.warn(`[worker] circuit breaker OPEN after ${consecutiveFailures} consecutive EHR failures (cooldown ${BREAKER_COOLDOWN_MS}ms)`);
          break;
        }
        if (attempt < maxTries) {
          const wait = backoffMs(attempt);
          console.warn(`[worker] EHR ${status} for ${jobId}: retry ${attempt + 1}/${maxTries} after ${wait}ms backoff`);
          await sleep(wait);
        }
      }
    }
    if (ehrResult === 'failed_auth') {
      await db.collection('jobs').updateOne(
        { _id: jobId }, { $set: { status: 'failed_auth', updatedAt: new Date() } },
      );
      await db.collection('appointments').updateOne(
        { _id: apptId },
        { $set: { status: 'failed_auth', updatedAt: new Date() } },
      );
      processedTotal += 1;
      latencyMsTotal += Date.now() - t0;
      return;
    }
    await db.collection('jobs').updateOne(
      { _id: jobId }, { $set: { status: 'done', updatedAt: new Date() } },
    );
    await db.collection('appointments').updateOne(
      { _id: apptId },
      { $set: { status: ehrResult === 'ok' ? 'processed' : 'processed_ehr_degraded', updatedAt: new Date() } },
    );
    processedTotal += 1;
    latencyMsTotal += Date.now() - t0;
  } catch (e) {
    failedTotal += 1;
    console.warn(`job ${jobId} failed: ${e.message}`);
    try {
      await db.collection('jobs').updateOne(
        { _id: jobId },
        { $set: { status: 'failed', lastError: String(e.message), updatedAt: new Date() } },
      );
      const doc = await db.collection('jobs').findOne({ _id: jobId });
      const attempts = (doc && doc.attempts) || 1;
      if (attempts < 3) {
        // P1.2: bounded exponential backoff before requeue (was immediate).
        const wait = backoffMs(attempts);
        console.warn(`[worker] job ${jobId} requeue ${attempts + 1}/3 after ${wait}ms backoff`);
        await sleep(wait);
        await db.collection('jobs').updateOne(
          { _id: jobId }, { $set: { status: 'queued', updatedAt: new Date() } },
        );
        await redis.rpush('jobs', JSON.stringify(item));
        retriesTotal += 1;
      } else {
        await redis.rpush('jobs:dead', JSON.stringify({ job_id: jobId, error: String(e.message) }));
        deadTotal += 1;
      }
    } catch (ie) {
      console.warn(`retry bookkeeping failed: ${ie.message}`);
    }
  }
}

async function main() {
  console.log(`[worker] up concurrency=${CONCURRENCY} fail_mode=${FAIL_MODE}`);
  for (;;) {
    try {
      const res = await redis.blpop('jobs', 5);
      if (!res) continue;
      await processOne(JSON.parse(res[1]));
    } catch (e) {
      console.warn(`loop error: ${e.message}`);
      await sleep(1000);
    }
  }
}

server.listen(PORT, '0.0.0.0', () => {
  console.log(`[worker] health on ${PORT}`);
  main();
});
