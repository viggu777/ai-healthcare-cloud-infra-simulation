// Phase 4 — k6 increased-load scenario (burst + backlog + drain).
// Ramps past the worker's drain rate (~2.5 jobs/s single consumer) so the Redis
// buffer fills, then stops and lets the queue drain — the PDF §23 "increased
// workload" case, measured. Sized so the backlog drains in ~4 min.
// Run: docker run --rm -i --network host -v "$PWD/k6:/scripts"
//        grafana/k6:1.0.0 run /scripts/load.js
// Watch during the run: Grafana queue-depth panel, QueueBacklog alert.
import http from 'k6/http';
import { check, sleep } from 'k6';

export const options = {
  stages: [
    { duration: '15s', target: 5 },
    { duration: '30s', target: 8 },
    { duration: '30s', target: 12 },
    { duration: '10s', target: 0 },
  ],
  thresholds: {
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<1000'],
  },
};

const GW = __ENV.GATEWAY_URL || 'http://localhost:8080';

export default function () {
  const payload = JSON.stringify({
    patient: `k6-load-${__VU}-${__ITER}`,
    doctor: 'dr-k6-load',
  });
  const res = http.post(`${GW}/appointments`, payload, {
    headers: { 'Content-Type': 'application/json' },
  });
  check(res, { 'enqueue 200': (r) => r.status === 200 });
  sleep(1.0);
}
