# perf.julialang.org on one EC2 host, in the shape of julia-perf's deployment
# (JuliaCI/julia-perf, infra/terraform): a dedicated VPC, an Elastic IP,
# Caddy for HTTP/HTTPS, a read-only Datasette at /db/, an S3 bucket for
# backups, ECR for the ingest image, Session Manager as the only operator
# path. The differences: the site is static files Caddy serves from the host,
# the ingest is a systemd timer running the image every two hours, a deploy
# pulls a new image and restarts (no instance replacement), and the data
# lives on its own EBS volume that outlives the instance.
#
# See docs/database-migration.md and README.md in this directory.

locals {
  common_tags = {
    Project     = "ci-timing"
    ManagedBy   = "Terraform"
    Environment = "production"
  }

  # Fixed settings that are not worth exposing as variables. Change them here;
  # they flow into the host env file, the scripts and the Caddyfile.
  data_mount_path  = "/var/lib/ci-timing"
  db_filename      = "ci-timing.sqlite"
  export_dir       = "export" # under data_mount_path; Caddy serves it at /data/
  site_dir         = "site"   # under data_mount_path; the static site
  datasette_port   = 8001     # served from the ingest image, see files/ci-timing-run-datasette
  api_port         = 8002     # db/serve.jl from the same image, see files/ci-timing-run-api
  caddy_image      = "caddy:2.8.4-alpine"
  caddy_data_dir   = "/var/lib/caddy/data"
  caddy_config_dir = "/var/lib/caddy/config"

  # The image runs as this fixed identity and the data directory is owned by it
  runtime_uid = 10001
  runtime_gid = 10001

  backup_prefix         = "runtime"
  backup_archive_dir    = "archive"
  backup_latest_name    = "latest.tar.gz"
  backup_retention_days = 30

  ecr_max_images      = 10
  ecr_repository_name = "${var.name_prefix}-ingest"
  backup_bucket_name  = lower("${var.name_prefix}-${data.aws_caller_identity.current.account_id}-${var.aws_region}-backups")
  # Created and filled outside Terraform (README), so the token is never
  # read into the state file; only its ARN is derived here
  token_parameter     = "/${var.name_prefix}/buildkite-api-token"
  token_parameter_arn = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${local.token_parameter}"
  image_parameter     = "/${var.name_prefix}/image-ref" # the deployed image, for a replacement host

  site_hostname = var.site_hostname == null ? "" : trimspace(var.site_hostname)
  # What the host pulls until the first deploy replaces it
  initial_image_ref = "${aws_ecr_repository.ingest.repository_url}:bootstrap"
}

data "aws_caller_identity" "current" {}

# ------------------------------------------------------------------ network --

resource "aws_vpc" "this" {
  cidr_block           = "10.43.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.name_prefix}-vpc" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name_prefix}-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.43.1.0/24"
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.name_prefix}-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = { Name = "${var.name_prefix}-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "instance" {
  name        = "${var.name_prefix}-instance"
  description = "Ingress for the ${var.name_prefix} host"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.name_prefix}-instance" }
}

# ---------------------------------------------------------------------- ecr --

resource "aws_ecr_repository" "ingest" {
  name                 = local.ecr_repository_name
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration {
    scan_on_push = true
  }
  encryption_configuration {
    encryption_type = "AES256"
  }
  tags = { Name = local.ecr_repository_name }
}

resource "aws_ecr_lifecycle_policy" "ingest" {
  repository = aws_ecr_repository.ingest.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire all but the newest ${local.ecr_max_images} images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = local.ecr_max_images
      }
      action = { type = "expire" }
    }]
  })
}

# ------------------------------------------------------------------ backups --

resource "aws_s3_bucket" "backups" {
  bucket = local.backup_bucket_name
  tags   = { Name = "${var.name_prefix}-backups" }
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "backups" {
  bucket = aws_s3_bucket.backups.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "EnforceTLS"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.backups.arn,
        "${aws_s3_bucket.backups.arn}/*",
      ]
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })
  depends_on = [aws_s3_bucket_public_access_block.backups]
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Versioning guards latest.tar.gz against an accidental overwrite or delete;
# the noncurrent rule keeps the two-hourly overwrites from accumulating.
resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket     = aws_s3_bucket.backups.id
  depends_on = [aws_s3_bucket_versioning.backups]

  rule {
    id     = "expire-old-runtime-backups"
    status = "Enabled"
    filter {
      prefix = "${local.backup_prefix}/${local.backup_archive_dir}/"
    }
    expiration {
      days = local.backup_retention_days
    }
  }
  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"
    filter {
      prefix = ""
    }
    noncurrent_version_expiration {
      noncurrent_days = 7
    }
    expiration {
      expired_object_delete_marker = true
    }
  }
  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"
    filter {
      prefix = ""
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# ------------------------------------------------------------------ secrets --

# The Buildkite token the fetchers use lives in the SSM parameter
# local.token_parameter, created and filled with `aws ssm put-parameter`
# (README). It used to be a resource here with ignore_changes on the value,
# which still read the decrypted value into the state file on every
# refresh; this forgets it without deleting the parameter.
removed {
  from = aws_ssm_parameter.buildkite_token
  lifecycle {
    destroy = false
  }
}

# The digest-pinned image last deployed: written by the deploy workflow,
# read by a fresh host so that a replacement comes up serving the site
# without waiting for the next deploy
resource "aws_ssm_parameter" "image_ref" {
  name        = local.image_parameter
  description = "Digest-pinned ingest image last deployed to the ${var.name_prefix} host"
  type        = "String"
  value       = "unset"
  lifecycle {
    ignore_changes = [value]
  }
}

data "aws_kms_alias" "ssm" {
  name = "alias/aws/ssm"
}

# ------------------------------------------------------------ instance role --

resource "aws_iam_role" "instance" {
  name = "${var.name_prefix}-instance-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

# Session Manager access (operator shell, and the SSM Run Command deploy path)
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "app" {
  name = "${var.name_prefix}-instance-app"
  role = aws_iam_role.instance.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
        ]
        Resource = aws_ecr_repository.ingest.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetBucketLocation", "s3:ListBucket"]
        Resource = aws_s3_bucket.backups.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:AbortMultipartUpload", "s3:GetObject", "s3:PutObject", "s3:GetObjectTagging"]
        Resource = "${aws_s3_bucket.backups.arn}/${local.backup_prefix}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = local.token_parameter_arn
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:PutParameter"]
        Resource = aws_ssm_parameter.image_ref.arn
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = data.aws_kms_alias.ssm.target_key_arn
      },
      {
        # AmazonSSMManagedInstanceCore allows reading every parameter in the
        # account, and anyone who can run commands on this host holds its
        # role: keep it to this project's parameters
        Effect      = "Deny"
        Action      = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath", "ssm:GetParameterHistory"]
        NotResource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/${var.name_prefix}/*"
      },
    ]
  })
}

resource "aws_iam_instance_profile" "instance" {
  name = "${var.name_prefix}-instance-profile"
  role = aws_iam_role.instance.name
}

# ----------------------------------------------------- github actions deploy --

# GitHub's OIDC provider is account-wide; created here if the account has
# none yet (see README for importing an existing one).
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# What .github/workflows/deploy.yml may do: push the image and tell the host
# to pull it. Only the listed refs of the repository can assume the role.
resource "aws_iam_role" "github_deploy" {
  name = "${var.name_prefix}-github-deploy"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = [for r in var.github_deploy_refs : "repo:${var.github_repository}:ref:${r}"]
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_deploy" {
  name = "${var.name_prefix}-github-deploy"
  role = aws_iam_role.github_deploy.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer",
          "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:PutImage",
          "ecr:DescribeImages",
        ]
        Resource = aws_ecr_repository.ingest.arn
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:SendCommand"]
        Resource = "arn:aws:ssm:${var.aws_region}::document/AWS-RunShellScript"
      },
      {
        # Only instances of this project, by tag: never another host in the account
        Effect   = "Allow"
        Action   = ["ssm:SendCommand"]
        Resource = "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*"
        Condition = {
          StringEquals = { "ssm:resourceTag/Project" = "ci-timing" }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations", "ec2:DescribeInstances"]
        Resource = "*"
      },
      {
        # The daily health check (health.yml) reads the age of the latest backup
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.backups.arn
      },
      {
        # The deploy records the image it shipped
        Effect   = "Allow"
        Action   = ["ssm:PutParameter"]
        Resource = aws_ssm_parameter.image_ref.arn
      },
    ]
  })
}

# --------------------------------------------------------------------- host --

data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

# The files cloud-init places on the host. Scripts and units are plain files
# under files/; the two that need Terraform values are rendered from templates.
locals {
  plain_files = {
    "/usr/local/bin/ci-timing-run-caddy"                   = "0755"
    "/usr/local/bin/ci-timing-run-datasette"               = "0755"
    "/usr/local/bin/ci-timing-run-api"                     = "0755"
    "/usr/local/bin/ci-timing-ingest"                      = "0755"
    "/usr/local/bin/ci-timing-backup"                      = "0755"
    "/usr/local/bin/ci-timing-archive"                     = "0755"
    "/usr/local/bin/ci-timing-restore-if-empty"            = "0755"
    "/usr/local/bin/ci-timing-deploy"                      = "0755"
    "/usr/local/bin/ci-timing-bootstrap"                   = "0755"
    "/etc/systemd/system/ci-timing-caddy.service"          = "0644"
    "/etc/systemd/system/ci-timing-datasette.service"      = "0644"
    "/etc/systemd/system/ci-timing-api.service"            = "0644"
    "/etc/systemd/system/ci-timing-bootstrap.service"      = "0644"
    "/etc/systemd/system/ci-timing-ingest.service"         = "0644"
    "/etc/systemd/system/ci-timing-ingest.timer"           = "0644"
    "/etc/systemd/system/ci-timing-archive.service"        = "0644"
    "/etc/systemd/system/ci-timing-archive.timer"          = "0644"
    "/etc/systemd/journald.conf.d/ci-timing-journald.conf" = "0644"
  }
  user_data_files = merge(
    { for p, mode in local.plain_files : p => { mode = mode, content = file("${path.module}/files/${basename(p)}") } },
    {
      "/etc/ci-timing.host.env" = { mode = "0600", content = templatefile("${path.module}/files/host.env.tftpl", {
        aws_region         = var.aws_region
        datasette_port     = local.datasette_port
        api_port           = local.api_port
        data_mount_path    = local.data_mount_path
        db_filename        = local.db_filename
        export_dir         = local.export_dir
        site_dir           = local.site_dir
        image_ref          = local.initial_image_ref
        ecr_repository_url = aws_ecr_repository.ingest.repository_url
        runtime_uid        = local.runtime_uid
        runtime_gid        = local.runtime_gid
        backup_bucket_name = aws_s3_bucket.backups.bucket
        backup_prefix      = local.backup_prefix
        backup_archive_dir = local.backup_archive_dir
        backup_latest_name = local.backup_latest_name
        caddy_image        = local.caddy_image
        caddy_data_dir     = local.caddy_data_dir
        caddy_config_dir   = local.caddy_config_dir
        token_parameter    = local.token_parameter
        image_parameter    = local.image_parameter
      }) }
      "/etc/caddy/Caddyfile" = { mode = "0644", content = templatefile("${path.module}/files/Caddyfile.tftpl", {
        public_ip       = aws_eip.site.public_ip
        public_hostname = local.site_hostname
        datasette_port  = local.datasette_port
        api_port        = local.api_port
        site_root       = "${local.data_mount_path}/${local.site_dir}"
        export_root     = "${local.data_mount_path}/${local.export_dir}"
      }) }
    }
  )
}

# The database, export, site and clones. Its own volume so that replacing
# the instance (every change to the files above does) keeps the data and
# the restore from S3 only ever runs onto a brand-new volume.
resource "aws_ebs_volume" "data" {
  availability_zone = var.availability_zone
  size              = var.data_volume_size_gb
  type              = "gp3"
  encrypted         = true
  tags              = { Name = "${var.name_prefix}-data" }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.site.id
  # A replacement detaches from the old instance first: stop it so the
  # filesystem is unmounted cleanly rather than yanked
  stop_instance_before_detaching = true
}

resource "aws_instance" "site" {
  ami                         = data.aws_ssm_parameter.al2023_ami.value
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.instance.id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.instance.name

  # Every host setting lives in this user_data, so a change to it replaces
  # the instance; the new host mounts the data volume (restoring from the
  # latest S3 backup only if the volume is new) and pulls the recorded
  # image. Image updates do not go through here (ci-timing-deploy pulls
  # and restarts in place).
  user_data_replace_on_change = true
  user_data_base64 = base64gzip(templatefile("${path.module}/cloud-init.yaml.tftpl", {
    files           = local.user_data_files
    runtime_uid     = local.runtime_uid
    runtime_gid     = local.runtime_gid
    data_mount_path = local.data_mount_path
    # On Nitro the volume shows up under its id, not the device name
    data_volume_dev  = "/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${replace(aws_ebs_volume.data.id, "-", "")}"
    export_dir       = local.export_dir
    site_dir         = local.site_dir
    caddy_data_dir   = local.caddy_data_dir
    caddy_config_dir = local.caddy_config_dir
  }))

  depends_on = [
    aws_iam_role_policy_attachment.ssm_core,
    aws_iam_role_policy.app,
    aws_s3_bucket_public_access_block.backups,
  ]

  lifecycle {
    # The SSM parameter tracks the newest AL2023 AMI; without this a routine
    # apply would replace the instance just because a new AMI was published.
    ignore_changes = [ami]
  }

  root_block_device {
    volume_size = var.root_volume_size_gb
    volume_type = "gp3"
    encrypted   = true
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required" # IMDSv2
  }

  tags = { Name = "${var.name_prefix}-site" }
}

resource "aws_eip" "site" {
  domain = "vpc"
  tags   = { Name = "${var.name_prefix}-site-eip" }
}

resource "aws_eip_association" "site" {
  instance_id   = aws_instance.site.id
  allocation_id = aws_eip.site.id
}
