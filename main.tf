# Minimal config — we're using this stack to run Tasks, not manage infrastructure
terraform {
  required_version = ">= 1.0"
}

output "info" {
  value = "This stack is used to test Twingate userspace + proxytunnel connectivity via Tasks."
}
