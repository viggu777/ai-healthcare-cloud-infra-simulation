/* Patient/API service — public entry behind gateway. Enqueues background work (MongoDB).
 * Node.js + Express port of the FastAPI implementation. Same routes, env vars,
 * response shapes and failure semantics (MongoDB + Redis).
 */
'use strict';

const crypto = require('crypto');
const express = require('express');
const { MongoClient } = require('mongodb');
const Redis = require('ioredis');
const { validateAppointment } = require('./validate');

const APP_VERSION = process.env.APP_VERSION || '0.1.0';
const MONGODB_URI = process.env.MONGODB_URI || '';
const MONGO_DB = process.env.MONGO_DB || 'healthcare';
const REDIS_URL = process.env.REDIS_URL || 'redis://queue:6379/0';
const AI_SERVICE_URL = process.env.AI_SERVICE_URL || 'http://ai-service:8001';
const AI_API_KEY = process.env.AI_API_KEY || '';
const EHR_URL = process.env.EHR_URL || 'http://ehr-mock:8002';
const EHR_TIMEOUT_S = parseFloat(process.env.EHR_TIMEOUT_S || '3');
const PORT = 8000;

const app = express();
app.use(express.json());

let requestsTotal = 0;
let errorsTotal = 0;
let latencyMsTotal = 0;
const startedAt = Date.now();

const redis = new Redis(REDIS_URL, { connectTimeout: 3000, maxRetriesPerRequest: 3 });
redis.on('error', (e) => console.error('[api] redis error:', e.message));

const mongo = MONGODB_URI
  ? new MongoClient(MONGODB_URI, { serverSelectionTimeoutMS: 3000 })
  : null;
if (mongo) mongo.connect().catch((e) => console.error('[api] mongo connect error:', e.message));

function mdb() {
  if (!mongo) throw new Error('MONGODB_URI not set');
  return mongo.db(MONGO_DB);
}

function hex12() {
  return crypto.randomBytes(6).toString('hex');
}

// DB liveness with one reconnect retry. The driver keeps a closed topology
// after a failed boot-time connect (e.g. least-privilege users synced into
// Mongo after this process first booted), so a failed ping retries one
// explicit connect before reporting failure. Makes /ready self-healing
// instead of sticky-false until container restart (CI health-gate root cause,
// 2026-09-19: runner /ready permanently "Topology is closed").
async function dbCheck() {
  try {
    await mongo.db('admin').command({ ping: 1 });
    return 'ok';
  } catch {
    try {
      await mongo.connect();
      await mongo.db('admin').command({ ping: 1 });
      return 'ok';
    } catch (e) {
      return `fail: ${e.message}`;
    }
  }
}

app.get('/health', (req, res) => {
  res.json({ status: 'ok', service: 'api', version: APP_VERSION, db: 'mongodb' });
});

app.get('/ready', async (req, res) => {
  const checks = {};
  checks.db = await dbCheck();
  try {
    await redis.ping();
    checks.queue = 'ok';
  } catch (e) {
    checks.queue = `fail: ${e.message}`;
  }
  const ready = Object.values(checks).every((v) => v === 'ok');
  res.json({ ready, checks });
});

app.get('/metrics', async (req, res) => {
  let qd;
  try {
    qd = await redis.llen('jobs');
  } catch {
    qd = -1;
  }
  const avg = requestsTotal ? latencyMsTotal / requestsTotal : 0;
  res.json({
    service: 'api',
    version: APP_VERSION,
    uptime_s: Math.round((Date.now() - startedAt) / 100) / 10,
    requests_total: requestsTotal,
    errors_total: errorsTotal,
    avg_latency_ms: Math.round(avg * 100) / 100,
    queue_depth: qd,
  });
});

// Phase 4: Prometheus exposition format (text). The JSON /metrics above is kept
// byte-identical for smoke.sh/workload.py; Prometheus scrapes this endpoint.
function promEscape(s) {
  return String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n');
}

app.get('/metrics/prom', async (req, res) => {
  let qd = -1;
  let dbReady = 0;
  let queueReady = 0;
  try {
    qd = await redis.llen('jobs');
  } catch { /* leave -1 */ }
  try {
    if (mongo) dbReady = (await dbCheck()) === 'ok' ? 1 : 0;
  } catch {
    dbReady = 0;
  }
  try {
    await redis.ping();
    queueReady = 1;
  } catch {
    queueReady = 0;
  }
  const uptimeS = Math.round((Date.now() - startedAt) / 100) / 10;
  const lines = [
    '# HELP api_requests_total Total appointment-create requests received.',
    '# TYPE api_requests_total counter',
    `api_requests_total ${requestsTotal}`,
    '# HELP api_errors_total Total failed appointment-create requests (4xx/5xx).',
    '# TYPE api_errors_total counter',
    `api_errors_total ${errorsTotal}`,
    '# HELP api_latency_ms_sum Sum of create-request latency (ms); divide rate by request rate for avg.',
    '# TYPE api_latency_ms_sum counter',
    `api_latency_ms_sum ${Math.round(latencyMsTotal * 100) / 100}`,
    '# HELP api_queue_depth Current Redis jobs-list depth (-1 = Redis unreachable).',
    '# TYPE api_queue_depth gauge',
    `api_queue_depth ${qd}`,
    '# HELP api_uptime_seconds Process uptime.',
    '# TYPE api_uptime_seconds gauge',
    `api_uptime_seconds ${uptimeS}`,
    '# HELP api_ready Readiness (1 = DB and queue both reachable).',
    '# TYPE api_ready gauge',
    `api_ready ${dbReady && queueReady ? 1 : 0}`,
    '# HELP api_dependency_ready Per-dependency readiness (labels: dep=db|queue).',
    '# TYPE api_dependency_ready gauge',
    `api_dependency_ready{dep="db"} ${dbReady}`,
    `api_dependency_ready{dep="queue"} ${queueReady}`,
    '# HELP deployment_info Deployed version (label: version). Always 1.',
    '# TYPE deployment_info gauge',
    `deployment_info{service="api",version="${promEscape(APP_VERSION)}"} 1`,
  ];
  res.type('text/plain; version=0.0.4').send(`${lines.join('\n')}\n`);
});

app.post('/appointments', async (req, res) => {
  const t0 = Date.now();
  requestsTotal += 1;
  const { patient, doctor } = req.body || {};
  const validationError = validateAppointment(req.body);
  if (validationError) {
    errorsTotal += 1;
    return res.status(422).json({ detail: validationError });
  }
  const jobId = `job-${hex12()}`;
  const apptId = `appt-${hex12()}`;
  try {
    const now = new Date();
    const db = mdb();
    await db.collection('appointments').insertOne({
      _id: apptId, patient, doctor, status: 'queued', createdAt: now, updatedAt: now,
    });
    await db.collection('jobs').insertOne({
      _id: jobId, type: 'appointment', status: 'queued',
      attempts: 0, createdAt: now, updatedAt: now,
    });
    await redis.rpush('jobs', JSON.stringify({ job_id: jobId, appointment_id: apptId }));
    latencyMsTotal += Date.now() - t0;
    console.log(`enqueued ${jobId} appt=${apptId}`);
    res.json({ job_id: jobId, appointment_id: apptId, status: 'queued' });
  } catch (e) {
    errorsTotal += 1;
    console.error('enqueue failed:', e.message);
    res.status(503).json({ detail: String((e && e.message) || e) });
  }
});

app.get('/appointments', async (req, res) => {
  try {
    const limit = Math.min(parseInt(req.query.limit, 10) || 20, 100);
    const rows = await mdb().collection('appointments')
      .find({}).sort({ _id: -1 }).limit(limit).toArray();
    res.json(rows.map((x) => ({ id: x._id, patient: x.patient, doctor: x.doctor, status: x.status || '' })));
  } catch (e) {
    res.status(503).json({ detail: String((e && e.message) || e) });
  }
});

app.post('/ai/query', async (req, res) => {
  try {
    const resp = await fetch(`${AI_SERVICE_URL}/infer`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-API-Key': AI_API_KEY },
      body: JSON.stringify(req.body || {}),
      signal: AbortSignal.timeout(5000),
    });
    const data = await resp.json();
    res.json({ ai_status: resp.status, ai_response: data });
  } catch (e) {
    res.status(502).json({ detail: `ai-service unreachable: ${e.message}` });
  }
});

app.get('/ehr/status', async (req, res) => {
  const mode = req.query.mode ? `?mode=${encodeURIComponent(req.query.mode)}` : '';
  const url = `${EHR_URL}/record/demo${mode}`;
  const t0 = Date.now();
  try {
    const resp = await fetch(url, { signal: AbortSignal.timeout(EHR_TIMEOUT_S * 1000) });
    const body = await resp.json();
    res.json({ ehr_status: resp.status, latency_ms: Math.round((Date.now() - t0) * 10) / 10, body });
  } catch (e) {
    res.status(504).json({ detail: `ehr unreachable/slow: ${e.message}` });
  }
});

app.listen(PORT, '0.0.0.0', () => console.log(`[api] listening on ${PORT}`));
