#!/usr/bin/env python3
"""Generate N appointments via gateway, report latency + queue drain."""
import sys, time, statistics, urllib.request, json

GW = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8080"
N = int(sys.argv[2]) if len(sys.argv) > 2 else 20

def post(path, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(GW + path, data=data, headers={"Content-Type": "application/json"}, method="POST" if data else "GET")
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read())

def get(path):
    with urllib.request.urlopen(GW + path, timeout=10) as r:
        return json.loads(r.read())

lats = []
for i in range(N):
    t0 = time.time()
    post("/appointments", {"patient": f"load-p{i}", "doctor": "dr-load"})
    lats.append((time.time() - t0) * 1000)
print(f"enqueued={N} avg_latency_ms={statistics.mean(lats):.1f} p95={sorted(lats)[int(0.95*N)-1]:.1f}")
for _ in range(30):
    m = get("/metrics")
    qd = m.get("queue_depth", -1)
    print(f"queue_depth={qd} requests={m.get('requests_total')}")
    if qd == 0:
        break
    time.sleep(2)
print("WORKLOAD DONE")
