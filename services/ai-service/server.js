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

app.get('/health', (req, res) => {
  res.json({ status: 'ok', service: 'ai-service' });
});

app.post('/infer', async (req, res) => {
  const key = req.header('x-api-key');
  if (!API_KEY || key !== API_KEY) {
    return res.status(401).json({ detail: 'invalid AI API key' });
  }
  await sleep(200); // simulate GPU/CPU inference
  const text = String((req.body && req.body.text) || '').slice(0, 200);
  res.json({ result: `mock-triage for ${text.length} chars`, model: 'mock-llm-0.1', ok: true });
});

app.listen(PORT, '0.0.0.0', () => console.log(`[ai-service] listening on ${PORT}`));
