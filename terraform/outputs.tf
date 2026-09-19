# P1.8 — human-readable surface of the resource graph (plan outputs).
output "environment" {
  description = "Environment this graph describes."
  value       = var.environment
}

output "published_ports" {
  description = "The only host-published ports (gateway sole ingress + localhost admin)."
  value = {
    gateway_http  = var.gateway_port
    gateway_https = var.gateway_tls_port
    grafana_admin = "127.0.0.1:${var.grafana_port}"
  }
}

output "service_count" {
  description = "Services in the graph (7 app + 8 observability)."
  value       = 15
}
