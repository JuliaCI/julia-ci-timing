# AWS deployment

One EC2 host for perf.julialang.org, in the shape of
[JuliaCI/julia-perf's](https://github.com/JuliaCI/julia-perf/tree/master/infra/terraform)
deployment. Background and the staged plan: [docs/database-migration.md](../../docs/database-migration.md).

What the stack creates: a dedicated VPC with one public subnet, a `t4g.medium`
(Graviton) instance with an Elastic IP and a security group exposing only 80
and 443, an IAM instance role (Session Manager, ECR pull, S3 backups, the
token parameter), an ECR repository for the ingest image, a private encrypted
S3 bucket for backups (versioned, archives expire after 30 days), an SSM
SecureString parameter for the Buildkite token, and GitHub's OIDC provider
plus a role that lets `.github/workflows/deploy.yml` push images and run the
deploy on the host.

On the host (all from cloud-init, files under `files/`):

- `ci-timing-caddy`: Caddy serving the static site from `/var/lib/ci-timing/site`,
  the rendered data files from `/var/lib/ci-timing/export` at `/data/`,
  `/healthz`, and proxying `/db/` to Datasette. HTTPS is automatic once
  `site_hostname` is set and pointed at the Elastic IP.
- `ci-timing-datasette`: public read-only SQL over the database, run from the
  ingest image. Its `ExecStartPre` restores the database, export and Caddy's
  certificates from the latest S3 backup on a fresh host.
- `ci-timing-ingest.timer`: every two hours, runs the image (`fetch_*.jl`,
  then `db/export.jl`) against `/var/lib/ci-timing/ci-timing.sqlite`, then
  `ci-timing-backup` uploads `runtime/latest.tar.gz` and publishes
  `/data/ci-timing.sqlite.gz`.
- `ci-timing-archive.timer`: daily dated copy of the latest backup.
- `ci-timing-deploy <image@sha256:...>`: what the workflow runs over SSM: pull,
  refresh the site directory, restart Datasette, start one ingest.

## Operating

Everything here runs as the `ci-timing` AWS profile (the `ci-timing-deployer`
role, which carries an explicit Deny on every julia-perf resource); log in
first with `aws sso login --sso-session julialang`.

```sh
export AWS_PROFILE=ci-timing
terraform init
terraform plan
terraform apply
```

First bring-up, in order: apply, upload a seed backup (a tar.gz holding
`ci-timing.sqlite` from `db/import_legacy.jl` and an `export/` directory) to
`s3://<backup bucket>/runtime/latest.tar.gz`, put the Buildkite token
(`aws ssm put-parameter --name /ci-timing/buildkite-api-token --type SecureString --overwrite --value ...`),
set the repository variable `CI_TIMING_DEPLOY_ROLE_ARN` to the
`github_deploy_role_arn` output, and run the deploy workflow.

A change to anything cloud-init places on the host replaces the instance
(`user_data_replace_on_change`); the new host restores from the latest backup,
so run `ci-timing-backup` on the old host first (`aws ssm send-command ...
--parameters 'commands=["/usr/local/bin/ci-timing-backup"]'`) if an ingest
has run since the last one.

Shell on the host: `aws ssm start-session --target <instance_id>`. Logs:
`journalctl -u ci-timing-ingest`, `-u ci-timing-datasette`, `-u ci-timing-caddy`.

State is local (`terraform.tfstate`, ignored by git). Losing it means
re-importing the resources; the data lives in the backup bucket.
