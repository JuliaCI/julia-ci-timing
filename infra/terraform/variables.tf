variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
}

variable "name_prefix" {
  description = "Prefix for resource names and tags. Must not be rustc-perf."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type for the host. Graviton (arm64); the image is built for linux/arm64."
  type        = string
}

variable "root_volume_size_gb" {
  description = "Root gp3 volume size in GiB. Holds the OS, Docker data, the SQLite database, the export and the report clones."
  type        = number
}

variable "site_hostname" {
  description = "Public hostname served over HTTPS by Caddy. Point it at the Elastic IP in external DNS. Leave null to serve plain HTTP on the Elastic IP only."
  type        = string
  default     = null
}

variable "github_repository" {
  description = "GitHub repository (owner/name) whose Actions may push images and trigger deploys through OIDC."
  type        = string
}

variable "github_deploy_refs" {
  description = "Git refs (refs/heads/<branch>) of github_repository allowed to deploy."
  type        = list(string)
}

variable "availability_zone" {
  description = "Availability zone of the public subnet. Pinned because not every zone stocks the instance type (us-east-1f had no t4g.medium)."
  type        = string
}
