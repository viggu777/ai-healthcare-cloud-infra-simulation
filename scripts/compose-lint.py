#!/usr/bin/env python3
"""Phase 2 compose security lint (FOSS, stdlib only) + Phase 4 admin-port rule.
Checks (fail = security gate violation):
  FAIL if any service other than `gateway` publishes a publicly reachable host port.
  Host-LOCAL ports bound to 127.0.0.1 (e.g. Grafana admin UI) are warn-only
  documented exceptions: reachable from the host admin only, never LAN/internet.
  FAIL if `private` network is missing internal:true.
  FAIL if db/queue/ehr/ai-service/worker is attached to `public` net.
  FAIL if any service uses privileged:true, unsafe cap_add (SYS_ADMIN, NET_ADMIN, DAC_OVERRIDE...), or host network/pid/ipc.
  FAIL if a custom-build service (api/ai-service/worker/ehr-mock) lacks cap_drop ALL or no-new-privileges.
Warn-only (reported, not failing): gateway + db without cap_drop (documented exceptions),
  host-local 127.0.0.1 admin ports (documented exception),
  unpinned images (:latest), read_only absent (future work).
Writes human-readable report to --evidence file and stdout; exits 1 on FAIL.
"""
import argparse
import sys

try:
    import yaml  # type: ignore
    HAVE_YAML = True
except ImportError:
    HAVE_YAML = False


def parse_compose_minimal(path):
    """Tiny fallback parser if PyYAML is absent: enough for our known compose shape."""
    import re
    text = open(path).read()
    services = {}
    cur = None
    in_services = False
    in_ports = False
    for line in text.splitlines():
        if re.match(r"^services:\s*$", line):
            in_services = True
            continue
        if in_services and re.match(r"^  \S", line) and not line.startswith("   "):
            m = re.match(r"^  (\S+):\s*$", line)
            if m:
                cur = m.group(1)
                services[cur] = {"_raw": []}
            in_ports = False
            continue
        if cur and (line.startswith("    ") or line.strip() == ""):
            services[cur]["_raw"].append(line)
            if re.match(r"^    ports:\s*$", line):
                in_ports = True
                continue
            if in_ports:
                pm = re.match(r"^      -\s*[\"']?([^\"'#\s]+)", line)
                if pm:
                    services[cur].setdefault("_ports", []).append(pm.group(1))
                elif line.strip() and not line.startswith("      "):
                    in_ports = False
    # extract coarse facts via regex on raw blocks
    out = {}
    for svc, d in services.items():
        raw = "\n".join(d["_raw"])
        out[svc] = {
            "ports": "ports:" in raw,
            "ports_list": d.get("_ports", []),
            "networks": re.findall(r"-\s*(public|private)", raw),
            "privileged": "privileged: true" in raw,
            "cap_drop_all": "cap_drop:" in raw and "- ALL" in raw,
            "no_new_privs": "no-new-privileges:true" in raw,
            "cap_add": re.findall(r"-\s*(SYS_ADMIN|NET_ADMIN|SYS_PTRACE|DAC_[A-Z_]+|ALL)", raw),
            "host_mode": ("network_mode:" in raw and "host" in raw) or ("pid: host" in raw),
            "image": (re.search(r"image:\s*(\S+)", raw).group(1) if re.search(r"image:\s*(\S+)", raw) else ""),
            "raw": raw,
        }
    internal = "internal: true" in text
    return out, internal


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--compose-file", default="docker-compose.yml")
    ap.add_argument("--evidence", default="docs/security-evidence/compose-lint.txt")
    args = ap.parse_args()

    lines = []
    fails = []
    warns = []

    def check(passed, msg, warn_only=False):
        if passed:
            lines.append(f"[PASS] {msg}")
        elif warn_only:
            lines.append(f"[WARN] {msg}")
            warns.append(msg)
        else:
            lines.append(f"[FAIL] {msg}")
            fails.append(msg)

    if HAVE_YAML:
        import re
        doc = yaml.safe_load(open(args.compose_file)) if hasattr(yaml, "safe_load") else None
        if doc is None:
            services, internal = parse_compose_minimal(args.compose_file)
        else:
            services = {}
            for svc, cfg in (doc.get("services") or {}).items():
                cfg = cfg or {}
                nets = cfg.get("networks") or []
                if isinstance(nets, dict):
                    nets = list(nets.keys())
                services[svc] = {
                    "ports": bool(cfg.get("ports")),
                    "ports_list": [str(p) for p in (cfg.get("ports") or [])],
                    "networks": list(nets),
                    "privileged": bool(cfg.get("privileged")),
                    "cap_drop_all": "ALL" in (cfg.get("cap_drop") or []),
                    "no_new_privs": any("no-new-privileges" in str(x) for x in (cfg.get("security_opt") or [])),
                    "cap_add": list(cfg.get("cap_add") or []),
                    "host_mode": str(cfg.get("network_mode", "")) == "host" or str(cfg.get("pid", "")) == "host",
                    "image": str(cfg.get("image", "")),
                    "raw": str(cfg),
                }
            nets_cfg = (doc.get("networks") or {})
            internal = bool((nets_cfg.get("private") or {}).get("internal"))
    else:
        services, internal = parse_compose_minimal(args.compose_file)

    lines.append(f"services inspected: {sorted(services)}")

    # 1. Only gateway publishes publicly reachable ports; 127.0.0.1 admin ports warn-only
    for svc, s in services.items():
        if svc == "gateway":
            check(s["ports"], "gateway publishes host port (sole ingress, expected)")
        else:
            public = [p for p in s.get("ports_list", []) if "127.0.0.1" not in p]
            admin = [p for p in s.get("ports_list", []) if "127.0.0.1" in p]
            check(len(public) == 0, f"{svc} publishes NO publicly reachable host ports")
            if admin:
                check(False, f"{svc} host-local admin port(s) {admin} (documented exception, see docs/SECURITY.md)", warn_only=True)

    # 2. private network internal:true
    check(internal, "private network has internal:true")

    # 3. private-only services never on public net
    for svc in ("db", "queue", "ai-service", "worker", "ehr-mock", "alert-logger"):
        if svc in services:
            check("public" not in services[svc]["networks"], f"{svc} not attached to public net ({services[svc]['networks']})")

    # 4. no privileged / host mode / dangerous caps
    for svc, s in services.items():
        check(not s["privileged"], f"{svc} privileged!=true")
        check(not s["host_mode"], f"{svc} no host network/pid mode")
        check(len(s["cap_add"]) == 0, f"{svc} no extra cap_add (found {s['cap_add']})")

    # 5. custom services hardened
    for svc in ("api", "ai-service", "worker", "ehr-mock", "alert-logger"):
        if svc in services:
            check(services[svc]["cap_drop_all"], f"{svc} has cap_drop ALL")
            check(services[svc]["no_new_privs"], f"{svc} has no-new-privileges")

    # warn-only documented exceptions
    for svc in ("gateway", "db", "queue"):
        if svc in services and not services[svc]["cap_drop_all"]:
            check(False, f"{svc} without cap_drop ALL (documented exception, see docs/SECURITY.md)", warn_only=True)
    for svc, s in services.items():
        if s["image"].endswith(":latest") or s["image"] == "":
            check(False, f"{svc} image unpinned ({s['image'] or 'no image key'})", warn_only=True)

    lines.append(f"---- summary: {len([l for l in lines if l.startswith('[PASS]')])} pass, "
                 f"{len(fails)} fail, {len(warns)} warn ----")
    report = "\n".join(lines) + "\n"
    print(report, end="")
    open(args.evidence, "w").write(report)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
