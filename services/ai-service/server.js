/* AI/Agent mock — private only. Requires shared secret, simulates inference latency.
 * Node.js + Express port. Same contract: POST /infer with X-API-Key header.
 */
'use strict';

const express = require('express');

const API_KEY = process.env.API_KEY || process.env.AI_API_KEY || '';
const PORT = 8001;

const app = express();
app.use(express.json());

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const startedAt = Date.now();
let inferTotal = 0;
let inferAuthFail = 0;

app.get('/health', (req, res) => {
  res.json({ status: 'ok', service: 'ai-service' });
});

// Prometheus exposition (scraped as job="ai-service"). Minimal, no new deps.
app.get('/metrics/prom', (req, res) => {
  const uptimeS = Math.round((Date.now() - startedAt) / 100) / 10;
  res.type('text/plain; version=0.0.4').send(
    '# HELP ai_infer_total Total /infer calls.\n'
    + '# TYPE ai_infer_total counter\n'
    + `ai_infer_total ${inferTotal}\n`
    + '# HELP ai_infer_auth_fail_total Rejected inferences (401).\n'
    + '# TYPE ai_infer_auth_fail_total counter\n'
    + `ai_infer_auth_fail_total ${inferAuthFail}\n`
    + '# HELP ai_uptime_seconds Process uptime.\n'
    + '# TYPE ai_uptime_seconds gauge\n'
    + `ai_uptime_seconds ${uptimeS}\n`,
  );
});

app.post('/infer', async (req, res) => {
  const key = req.header('x-api-key');
  inferTotal += 1;
  if (!API_KEY || key !== API_KEY) {
    inferAuthFail += 1;
    return res.status(401).json({ detail: 'invalid AI API key' });
  }
  await sleep(200); // simulate GPU/CPU inference
  const text = String((req.body && req.body.text) || '').slice(0, 200);
  res.json({ result: `mock-triage for ${text.length} chars`, model: 'mock-llm-0.1', ok: true });
});

app.listen(PORT, '0.0.0.0', () => console.log(`[ai-service] listening on ${PORT}`));
