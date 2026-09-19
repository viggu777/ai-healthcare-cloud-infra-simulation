/* External EHR mock — success, slow, timeout, 500, 401, 503, unknown.
 * Control via ?mode= or EHR_MODE env. Modes: ok|slow|timeout|error|auth_fail|unavailable|unknown
 * Node.js + Express port. Same modes, timings and response bodies as the FastAPI version.
 */
'use strict';

const express = require('express');

const DEFAULT_MODE = process.env.EHR_MODE || 'ok';
const PORT = 8002;

const app = express();

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

app.get('/health', (req, res) => {
  res.json({ status: 'ok', service: 'ehr-mock', default_mode: DEFAULT_MODE });
});

app.get('/record/:recordId', async (req, res) => {
  const m = String(req.query.mode || DEFAULT_MODE).toLowerCase();
  const id = req.params.recordId;
  if (m === 'slow') {
    // NOTE (MERN port): 2s, not 3s. The Python mock slept 3s against a 3s client
    // timeout (EHR_TIMEOUT_S) — a boundary race Node's precise timers always lose
    // (abort at exactly 3000ms beats a 3000ms sleep -> spurious 504). 2s keeps
    // "slow-but-ok" distinct from "timeout" (10s), matching Phase 1 behavior.
    await sleep(2000);
    return res.json({ id, mode: m, data: 'slow-but-ok' });
  }
  if (m === 'timeout') {
    await sleep(10000); // exceeds client timeout -> client observes timeout/retry
    return res.json({ id, mode: m });
  }
  if (m === 'error') {
    return res.status(500).json({ error: 'temporary EHR failure', retryable: true });
  }
  if (m === 'auth_fail') {
    return res.status(401).json({ error: 'EHR auth failed', retryable: false });
  }
  if (m === 'unavailable') {
    return res.status(503).json({ error: 'EHR unavailable', retryable: true });
  }
  if (m === 'unknown') {
    // outcome unknown: randomly succeed/fail to force idempotency reasoning
    if (Math.random() < 0.5) {
      return res.status(500).json({ error: 'unknown outcome, retry safely', retryable: true });
    }
    return res.json({ id, mode: m, data: 'maybe-ok' });
  }
  return res.json({ id, mode: 'ok', data: 'ehr-record-ok' });
});

app.listen(PORT, '0.0.0.0', () => console.log(`[ehr-mock] listening on ${PORT}`));
