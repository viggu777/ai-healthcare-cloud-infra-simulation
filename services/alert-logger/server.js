// P1.4 — local alert-notification sink (simulation-grade "someone gets told").
// Receives Alertmanager webhook POSTs and appends one JSON line per delivery
// to /data/alert-notifications.log (bind-mounted to ./monitoring/alert-notifications
// on the host, so the artifact is directly inspectable). No external service,
// no credentials, no network egress. Bare Node http — zero dependencies.
'use strict';

const fs = require('fs');
const http = require('http');

const PORT = 9089;
const LOG_FILE = '/data/alert-notifications.log';

const server = http.createServer((req, res) => {
  if (req.method === 'GET' && req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok', service: 'alert-logger' }));
    return;
  }
  if (req.method === 'POST' && req.url === '/notify') {
    let body = '';
    req.on('data', (d) => { body += d; });
    req.on('end', () => {
      try {
        const payload = JSON.parse(body);
        const record = {
          received_at: new Date().toISOString(),
          alerts: (payload.alerts || []).map((a) => ({
            status: a.status,
            alertname: a.labels && a.labels.alertname,
            severity: a.labels && a.labels.severity,
            summary: a.annotations && a.annotations.summary,
            startsAt: a.startsAt,
            endsAt: a.endsAt,
          })),
        };
        fs.appendFileSync(LOG_FILE, `${JSON.stringify(record)}\n`);
        console.log(`[alert-logger] recorded ${record.alerts.length} alert(s): ${record.alerts.map((a) => `${a.status}:${a.alertname}`).join(', ')}`);
      } catch (e) {
        console.error(`[alert-logger] bad payload: ${e.message}`);
      }
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ recorded: true }));
    });
    return;
  }
  res.writeHead(404);
  res.end();
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`[alert-logger] listening on ${PORT}, appending to ${LOG_FILE}`);
});
