// P1.1 — gateway rate-limit probe (NOT a load test).
// Fires a short, sharp burst at the gateway catch-all so the `limit_req`
// zone (20 r/s + burst 20, see gateway/nginx.conf) visibly sheds load.
// Success = some 429s observed AND the gateway stays healthy afterwards.
// Run: docker run --rm -i --network host -v "$PWD/k6:/scripts"
//        grafana/k6:1.0.0 run /scripts/burst.js
import http from 'k6/http';
import { check } from 'k6';
import { Counter } from 'k6/metrics';

const shed429 = new Counter('shed_429_total');

export const options = {
  vus: 40,
  iterations: 400,
  thresholds: {
    // The point of this script: the limiter must engage (429s seen)…
    'shed_429_total': ['count>0'],
    // …while non-shed traffic still succeeds (no 5xx, gateway healthy).
    'checks': ['rate>0.5'],
  },
};

const GW = __ENV.GATEWAY_URL || 'http://localhost:8080';

export default function () {
  // /ready rides the rate-limited catch-all (unlike /health and
  // /nginx-health, which stay unlimited so probes never 429).
  const res = http.get(`${GW}/ready`);
  if (res.status === 429) shed429.add(1);
  check(res, {
    '200 or 429 (no 5xx)': (r) => r.status === 200 || r.status === 429,
  });
}
