# P1.8 — environment-shaped variables (the dials that differ per environment).
# Documentation-grade: these mirror environments/dev.env + prod.env so the
# conceptual jump to real cloud IaC is small. Compose remains the actual
# local execution engine; nothing here provisions anything (see main.tf).
# Placeholder-only defaults (accepted risk R4 — Gitleaks-clean, same posture
# as environments/*.env): inject real secrets via tfvars/host env before any
# shared use.

variable "environment" {
  description = "Environment label (dev | prod-like)."
  type        = string
  default     = "dev"
}

variable "project_name" {
  description = "Compose project name (network/volume namespace)."
  type        = string
  default     = "ai-healthcare-dev"
}

variable "app_version" {
  description = "Run tag for the custom-built images (git SHA in CI, semver alias for humans)."
  type        = string
  default     = "0.1.0-dev"
}

variable "gateway_port" {
  description = "Host port publishing the gateway :80 listener."
  type        = number
  default     = 8080
}

variable "gateway_tls_port" {
  description = "Host port publishing the gateway :443 listener (self-signed, P1.1)."
  type        = number
  default     = 8443
}

variable "grafana_port" {
  description = "Host port for the localhost-bound Grafana admin UI."
  type        = number
  default     = 3000
}

variable "mongo_user" {
  description = "MongoDB root/app username (placeholder)."
  type        = string
  default     = "app"
}

variable "mongo_api_user" {
  description = "MongoDB least-privilege API user (readWrite on healthcare)."
  type        = string
  default     = "api_user"
}

variable "mongo_worker_user" {
  description = "MongoDB least-privilege worker user (readWrite on healthcare)."
  type        = string
  default     = "worker_user"
}

variable "mongo_password" {
  description = "MongoDB app password (placeholder — sensitive)."
  type        = string
  default     = "dev_only_change_me"
  sensitive   = true
}

variable "mongo_db" {
  description = "MongoDB database name."
  type        = string
  default     = "healthcare"
}

variable "ai_api_key" {
  description = "Mock AI-service API key (placeholder — sensitive)."
  type        = string
  default     = "dev_ai_key_change_me"
  sensitive   = true
}

variable "grafana_admin_password" {
  description = "Grafana admin password (placeholder — sensitive)."
  type        = string
  default     = "dev_only_change_me"
  sensitive   = true
}

variable "worker_concurrency" {
  description = "Worker consumer concurrency hint."
  type        = number
  default     = 2
}

variable "worker_fail_mode" {
  description = "Worker fault-injection mode (off|slow|error|crash)."
  type        = string
  default     = "off"
}

variable "ehr_mode" {
  description = "Mock EHR response mode (ok|slow|timeout|error|auth_fail|unavailable)."
  type        = string
  default     = "ok"
}

variable "log_level" {
  description = "Service log verbosity."
  type        = string
  default     = "debug"
}
