# AWS deployment

One EC2 host for perf.julialang.org, in the shape of
[JuliaCI/julia-perf's](https://github.com/JuliaCI/julia-perf/tree/master/infra/terraform)
deployment. Background and the staged plan: [docs/database-migration.md](../../docs/database-migration.md).

What the stack creates: a dedicated VPC with one public subnet, a `t4g.medium`
(Graviton) instance with an Elastic IP and a security group exposing only 80
and 443, a separate encrypted gp3 data volume mounted at `/var/lib/ci-timing`
that outlives the instance (`prevent_destroy`), an IAM instance role (Session
Manager, ECR pull, S3 backups, the token parameter), an ECR repository for the
ingest image, a private encrypted S3 bucket for backups (versioned, archives
expire after 30 days), and GitHub's OIDC provider plus a role that lets
`.github/workflows/deploy.yml` push images and run the deploy on the host.
The Buildkite token's SSM SecureString parameter is created outside Terraform
so its value never reaches the state file.

On the host (all from cloud-init, files under `files/`):

- `ci-timing-caddy`: Caddy serving the static site from `/var/lib/ci-timing/site`,
  the rendered data files from `/var/lib/ci-timing/export` at `/data/`,
  `/healthz`, and proxying `/db/` to Datasette. HTTPS is automatic once
  `site_hostname` is set and pointed at the Elastic IP.
- `ci-timing-datasette`: public read-only SQL over the database, run from the
  ingest image. Its `ExecStartPre` restores the database, export and Caddy's
  certificates from the latest S3 backup on a fresh host.
- `ci-timing-api`: the site's API (`db/serve.jl`) from the same image, proxied
  at `/api/`; the browser reads the database through it with a time window.
  The `/data/` files are for scripts.
- `ci-timing-ingest.timer`: every hour, runs the image (`fetch_*.jl`,
  then `db/export.jl`) against `/var/lib/ci-timing/ci-timing.sqlite`, then
  `ci-timing-backup` uploads `runtime/latest.tar.gz` and publishes
  `/data/ci-timing.sqlite.gz`.
- `ci-timing-archive.timer`: daily dated copy of the latest backup.
- `ci-timing-deploy <image@sha256:...>`: what the workflow runs over SSM: pull,
  refresh the site directory, restart Datasette and the API, start one ingest.

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
`ci-timing.sqlite` and an `export/` directory; the bucket's `runtime/` and
daily archives are what a new data volume restores) to
`s3://<backup bucket>/runtime/latest.tar.gz`, create the Buildkite token
parameter
(`aws ssm put-parameter --name /ci-timing/buildkite-api-token --type SecureString --overwrite --value ...`),
set the repository variable `CI_TIMING_DEPLOY_ROLE_ARN` to the
`github_deploy_role_arn` output, and run the deploy workflow.

A change to anything cloud-init places on the host replaces the instance
(`user_data_replace_on_change`). The data volume is stopped, detached and
attached to the new host, which pulls the recorded image and carries on with
the same database; a backup first (`aws ssm send-command ...
--parameters 'commands=["/usr/local/bin/ci-timing-backup"]'`) is still cheap
insurance. Only a brand-new volume restores from S3.

The first apply of the data volume replaces the instance too, and that new
volume is empty: it restores from the latest backup, so run `ci-timing-backup`
right before. The same apply forgets the token parameter without deleting it
(the `removed` block); afterwards delete `terraform.tfstate.backup` and any
`terraform.tfstate.*.backup`, which still hold the decrypted token from the
resource's time.

A one-off fetcher run (a backfill) runs the image the way the ingest does,
under the ingest lock so the timer waits for it, in the background:

```sh
aws ssm send-command --instance-ids <instance_id> --document-name AWS-RunShellScript \
  --parameters 'commands=["set -a; . /etc/ci-timing.host.env; set +a; nohup flock /var/lock/ci-timing-ingest.lock docker run --rm --user $CI_TIMING_RUNTIME_UID:$CI_TIMING_RUNTIME_GID --env CI_TIMING_DB=/data/$CI_TIMING_DB_FILENAME --mount type=bind,src=$CI_TIMING_DATA_DIR,dst=/data $CI_TIMING_IMAGE_REF julia /app/fetch_pkgeval.jl --backfill-packages 365 > /var/log/ci-timing-backfill.log 2>&1 &"]'
```

(`fetch_benchmarks.jl --backfill-stats` re-parses every report's tarball;
both were run once on 2026-09-21.)

Shell on the host: `aws ssm start-session --target <instance_id>`. Logs:
`journalctl -u ci-timing-ingest`, `-u ci-timing-datasette`, `-u ci-timing-api`,
`-u ci-timing-caddy`.

State is local (`terraform.tfstate`, ignored by git). Losing it means
re-importing the resources; the data lives in the backup bucket.
