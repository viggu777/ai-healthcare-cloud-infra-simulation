// Phase 4 — k6 normal-load scenario (baseline comparison).
// Drives the public gateway the way an evaluator would: create appointments,
// expect immediate 200 (enqueue, not synchronous processing).
// Run: docker run --rm -i --network host -v "$PWD/k6:/scripts"
//        grafana/k6:1.0.0 run /scripts/smoke.js
// Baseline (scripts/workload.py, Node stack): avg ~16ms, p95 ~22ms, drain to 0.
import http from 'k6/http';
import { check, sleep } from 'k6';

export const options = {
  vus: 5,
  duration: '60s',
  thresholds: {
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<500'],
  },
};

const GW = __ENV.GATEWAY_URL || 'http://localhost:8080';

export default function () {
  const payload = JSON.stringify({
    patient: `k6-p-${__VU}-${__ITER}`,
    doctor: 'dr-k6',
  });
  const res = http.post(`${GW}/appointments`, payload, {
    headers: { 'Content-Type': 'application/json' },
  });
  check(res, { 'enqueue 200': (r) => r.status === 200 });
  sleep(0.5);
}
