# P1.8 — resource graph of the simulation, expressed declaratively.
#
# ROLE (explicit scope, unchanged from docs/TARGET_ARCHITECTURE.md §12):
# documentation-grade, NOT a provisioner. `docker compose` remains the actual
# local execution engine; these terraform_data resources mirror the Compose
# topology 1:1 (15 services, 2 networks, published ports, dependencies) so
# `tofu plan` / `terraform plan` renders the same graph a reviewer sees in §2,
# and so the jump to real cloud IaC later is small. Applying this graph
# creates no infrastructure — by design (there is no provider block on purpose).
#
# terraform_data is provider-less (built into Terraform ≥1.4 / OpenTofu), so
# init needs no registry access and plan works fully offline.

terraform {
  required_version = ">= 1.4"
}

# ---- networks (mirrors docker-compose.yml networks:) ----
resource "terraform_data" "network_public" {
  input = {
    name     = "${var.project_name}_public"
    internal = false
    note     = "Gateway + documented dual-homed bridges (api, grafana, nginx-exporter)."
  }
}

resource "terraform_data" "network_private" {
  input = {
    name     = "${var.project_name}_private"
    internal = true
    note     = "No internet route. All app/data/observability traffic except the gateway proxies."
  }
}

# ---- app plane (7 services) ----
resource "terraform_data" "gateway" {
  input = {
    image    = "nginx:alpine@sha256:4870c12cd2ca986de501a804b4f506ad3875a0b1874940ba0a2c7f763f1855b2"
    networks = [terraform_data.network_public.id]
    ports    = ["${var.gateway_port}:80", "${var.gateway_tls_port}:443"]
    depends  = ["api"]
    notes    = "Sole published ports. P1.1: :443 self-signed, limit_req 20r/s+b20 (429), /nginx-health."
  }
}

resource "terraform_data" "api" {
  input = {
    image    = "ai-healthcare/api:${var.app_version}"
    networks = [terraform_data.network_public.id, terraform_data.network_private.id]
    ports    = []
    depends  = ["db", "queue"]
    notes    = "Dual-homed, no published port. /health /ready /metrics /metrics/prom. P1.6 prod limits via compose override."
  }
}

resource "terraform_data" "ai_service" {
  input = {
    image    = "ai-healthcare/ai-service:${var.app_version}"
    networks = [terraform_data.network_private.id]
    ports    = []
    depends  = []
    notes    = "Private-only mock. POST /ai/query from api only (P0.4: worker never calls AI)."
  }
}

resource "terraform_data" "worker" {
  input = {
    image    = "ai-healthcare/worker:${var.app_version}"
    networks = [terraform_data.network_private.id]
    ports    = []
    depends  = ["db", "queue"]
    notes    = "BLPOP consumer. P1.2: bounded EHR retry+backoff, breaker (5/15s), 401->failed_auth. Concurrency=${var.worker_concurrency} fail_mode=${var.worker_fail_mode}."
  }
}

resource "terraform_data" "queue" {
  input = {
    image    = "redis:7-alpine@sha256:520775a41a63e77e06c73e35d2fd9cc15921a609516818796b4ecbb813078bc7"
    networks = [terraform_data.network_private.id]
    ports    = []
    depends  = []
    notes    = "Redis 7, AOF. Private-only, no cap_drop (R3: entrypoint needs chown)."
  }
}

resource "terraform_data" "db" {
  input = {
    image    = "mongo:7-jammy@sha256:84c4a18b60a0e73d1577112b0a600b46cab477c64cfe0ff36d0647bbca055bd0"
    networks = [terraform_data.network_private.id]
    ports    = []
    depends  = []
    notes    = "MongoDB 7, named volume, db/mongo-init.js. User=${var.mongo_user} db=${var.mongo_db}."
  }
}

resource "terraform_data" "ehr_mock" {
  input = {
    image    = "ai-healthcare/ehr-mock:${var.app_version}"
    networks = [terraform_data.network_private.id]
    ports    = []
    depends  = []
    notes    = "Simulated external EHR (trust boundary is logical, P0.4). mode=${var.ehr_mode}: ok|slow|timeout|error|auth_fail|unavailable."
  }
}

# ---- observability plane (8 services, Phase 4 + P1.3/P1.4) ----
resource "terraform_data" "prometheus" {
  input = {
    image    = "prom/prometheus:v3.6.0@sha256:76947e7ef22f8a698fc638f706685909be425dbe09bd7a2cd7aca849f79b5f64"
    networks = [terraform_data.network_private.id]
    ports    = []
    depends  = []
    notes    = "15s scrape of api/worker/nginx/redis/mongodb/pushgateway. P1.3 healthcheck -/healthy. 7d/1GB retention."
  }
}

resource "terraform_data" "alertmanager" {
  input = {
    image    = "prom/alertmanager:v0.28.0@sha256:d5155cfac40a6d9250ffc97c19db2c5e190c7bc57c6b67125c94903358f8c7d8"
    networks = [terraform_data.network_private.id]
    ports    = []
    depends  = ["prometheus"]
    notes    = "P1.4: receiver alert-log posts to alert-logger:9089 (file sink), send_resolved=true."
  }
}

resource "terraform_data" "pushgateway" {
  input = {
    image    = "prom/pushgateway:v1.10.0@sha256:7a4d0696a24ef4e8bad62bee5656855a0aff2f26416d8cb32009dc28d6263604"
    networks = [terraform_data.network_private.id]
    ports    = []
    depends  = []
    notes    = "Pipeline/security status pushes (via api container stdin pipe)."
  }
}

resource "terraform_data" "grafana" {
  input = {
    image    = "grafana/grafana:11.6.0@sha256:62d2b9d20a19714ebfe48d1bb405086081bc602aa053e28cf6d73c7537640dfb"
    networks = [terraform_data.network_public.id, terraform_data.network_private.id]
    ports    = ["127.0.0.1:${var.grafana_port}:3000"]
    depends  = ["prometheus"]
    notes    = "Dual-homed for the localhost-bound admin port (P0.4). 17-panel dashboard provisioned in dev+prod."
  }
}

resource "terraform_data" "redis_exporter" {
  input = {
    image    = "oliver006/redis_exporter:v1.68.0@sha256:e7e96895407ae28cf28dc97c73c9cd958c5adb4746120e2664569393436c1bd0"
    networks = [terraform_data.network_private.id]
    ports    = []
    depends  = ["queue"]
    notes    = "Scratch image: no container healthcheck (P1.3) — watched via up{job=redis} + ExporterDown."
  }
}

resource "terraform_data" "mongodb_exporter" {
  input = {
    image    = "percona/mongodb_exporter:0.40.0@sha256:d66daa6aff0513860d1577cee3b55ab82fde43394f8319d7b4674411b9153cce"
    networks = [terraform_data.network_private.id]
    ports    = []
    depends  = ["db"]
    notes    = "No shell in image (P1.3) — watched via up{job=mongodb} + DBUnavailable."
  }
}

resource "terraform_data" "nginx_exporter" {
  input = {
    image    = "nginx/nginx-prometheus-exporter:1.4.2@sha256:6edfb73afd11f2d83ea4e8007f5068c3ffaa38078a6b0ad1339e5bd2f637aacd"
    networks = [terraform_data.network_public.id, terraform_data.network_private.id]
    ports    = []
    depends  = ["gateway"]
    notes    = "Dual-homed to resolve the public-only gateway (P0.4). Watched via up{job=nginx} + ExporterDown."
  }
}

resource "terraform_data" "alert_logger" {
  input = {
    image    = "ai-healthcare/alert-logger:${var.app_version}"
    networks = [terraform_data.network_private.id]
    ports    = []
    depends  = []
    notes    = "P1.4 zero-dep Node sink: Alertmanager webhooks -> host file monitoring/alert-notifications/."
  }
}
