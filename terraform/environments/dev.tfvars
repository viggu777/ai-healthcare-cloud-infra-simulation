# P1.8 — environment values mirroring environments/dev.env.
project_name           = "ai-healthcare-dev"
environment            = "dev"
app_version            = "0.1.0-dev"
gateway_port           = 8080
gateway_tls_port       = 8443
grafana_port           = 3000
mongo_user             = "app"
mongo_password         = "dev_only_change_me"
mongo_db               = "healthcare"
ai_api_key             = "dev_ai_key_change_me"
grafana_admin_password = "dev_only_change_me"
worker_concurrency     = 2
worker_fail_mode       = "off"
ehr_mode               = "ok"
log_level              = "debug"
