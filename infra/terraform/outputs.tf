output "site_url" {
  description = "Primary URL for the site."
  value       = local.site_hostname == "" ? "http://${aws_eip.site.public_ip}" : "https://${local.site_hostname}"
}

output "site_public_ip" {
  description = "Elastic IP attached to the host. Point external DNS here."
  value       = aws_eip.site.public_ip
}

output "instance_id" {
  description = "EC2 instance ID of the host."
  value       = aws_instance.site.id
}

output "ecr_repository_url" {
  description = "ECR repository the deploy workflow pushes the ingest image to."
  value       = aws_ecr_repository.ingest.repository_url
}

output "backup_bucket_name" {
  description = "S3 bucket holding the database backup archives."
  value       = aws_s3_bucket.backups.bucket
}

output "github_deploy_role_arn" {
  description = "Role .github/workflows/deploy.yml assumes through OIDC."
  value       = aws_iam_role.github_deploy.arn
}

output "buildkite_token_parameter" {
  description = "SSM parameter to put the Buildkite API token in (created outside Terraform, see README)."
  value       = local.token_parameter
}

output "data_volume_id" {
  description = "EBS volume holding the database; it outlives the instance."
  value       = aws_ebs_volume.data.id
}
