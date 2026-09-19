/* Background worker — consumes Redis queue, updates MongoDB, calls EHR mock.
 * Observable: queue depth, processing latency, failed jobs, retries, restarts.
 * Fail modes via WORKER_FAIL_MODE: off|slow|error|crash
 * Node.js port of worker.py. Same job document shapes, retry policy
 * (retry while attempts<3, else jobs:dead list) and /health contract on :8003.
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
const ehrOutcomes = { ok: 0, error_5xx: 0, auth_401: 0, unavailable_503: 0, timeout: 0, other: 0 };
const startedAt = Date.now();

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

// Health endpoint (bare http — no web framework needed in the worker).
const server = http.createServer(async (req, res) => {
  if (req.method === 'GET' && (req.url === '/health' || req.url === '/metrics')) {
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
    // call EHR (timeout 3s, retryable) — record outcome but don't fail job on EHR 5xx
    let ehrOk = false;
    try {
      const resp = await fetch(`${EHR_URL}/record/${apptId}`, { signal: AbortSignal.timeout(3000) });
      if (resp.status === 200) ehrOutcomes.ok += 1;
      else if (resp.status === 500) ehrOutcomes.error_5xx += 1;
      else if (resp.status === 401) ehrOutcomes.auth_401 += 1;
      else if (resp.status === 503) ehrOutcomes.unavailable_503 += 1;
      else ehrOutcomes.other += 1;
      ehrOk = resp.status === 200;
    } catch (e) {
      ehrOutcomes.timeout += 1;
      console.warn(`EHR call failed for ${jobId}: ${e.message}`);
    }
    await db.collection('jobs').updateOne(
      { _id: jobId }, { $set: { status: 'done', updatedAt: new Date() } },
    );
    await db.collection('appointments').updateOne(
      { _id: apptId },
      { $set: { status: ehrOk ? 'processed' : 'processed_ehr_degraded', updatedAt: new Date() } },
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
