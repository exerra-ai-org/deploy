# LinkedOut: one instance running k3s, and a managed Postgres beside it.
#
# ─────────────────────────────────────────────────────────────────────────────
# WHY ONE BOX AND NOT FARGATE, WHICH THIS FILE USED TO DESCRIBE.
#
# LinkedOut's account fleet needs Kubernetes and the code already speaks it:
# AccountsService creates a StatefulSet per LinkedIn account, proxies co-browse
# through the API server's pods/portforward subresource, and execs into the
# worker container to run login.js so the session is minted by the browser that
# will use it. The first draft here put the API and portal on Fargate and left
# the fleet for a week of porting work.
#
# Three things killed that. It was more expensive at every account count we will
# see this year -- one instance carries the control plane AND the fleet, where
# Fargate needed a load balancer, two always-on tasks and a Redis on top. It was
# more work. And the porting would have landed on the k8s.Exec path that mints
# sessions, which is the single worst place in this codebase to introduce a bug.
#
# EKS was never in it: $73 a month for a control plane, on top of the same
# instance, to buy managed etcd that a three-account fleet has no use for.
# ─────────────────────────────────────────────────────────────────────────────

# data.aws_vpc.default and data.aws_subnets.default are declared in acrm.tf.
# Same root module, so they are shared rather than redeclared.

locals {
  linkedout_tags = {
    ManagedBy = "terraform"
    App       = "linkedout"
    # Both tags are load-bearing: the deploy role's ssm:SendCommand is
    # conditioned on them, so an instance missing either cannot be deployed to,
    # and an instance belonging to another app cannot be reached by this one.
    DeployGroup = var.deploy_group_tag
  }
}

# ---- the instance -----------------------------------------------------------

# Ubuntu 24.04 LTS, amd64.
#
# amd64 is not a default here, it is a constraint. .github/workflows/images.yml
# builds linux/amd64 only and says why: the worker image carries a Chromium build
# that would need verifying separately on arm rather than assumed to work. So no
# Graviton, and the instance families below are the Intel ones.
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

# m6i.large: 2 vCPU, 8 GiB, about seventy dollars a month.
#
# NOT t3.large, which is nine dollars cheaper and wrong for this workload. t3 is
# burstable: 2 vCPUs with a 30% sustained baseline, and surplus drawn from
# credits. A headed Chromium rendering a real LinkedIn page is not a bursty load,
# it is a steady one, and three of them exhaust the credit balance and then
# throttle -- or, in unlimited mode, quietly bill for the surplus. Either way the
# symptom is "the fleet got slow" with nothing in any log saying why.
#
# 8 GiB holds the control plane plus two or three accounts. Resizing is a stop,
# a change and a start -- minutes, and no migration -- so this is a starting
# point rather than a ceiling. See the memory budget in the k3s runbook.
variable "linkedout_instance_type" {
  type    = string
  default = "m6i.large"
}

resource "aws_instance" "linkedout" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.linkedout_instance_type
  subnet_id              = sort(data.aws_subnets.default.ids)[0]
  vpc_security_group_ids = [aws_security_group.linkedout.id]
  iam_instance_profile   = aws_iam_instance_profile.linkedout.name

  root_block_device {
    volume_size = 50 # OS + container images + 5 GiB per account PVC
    volume_type = "gp3"
    encrypted   = true
  }

  # IMDSv2 required. The instance profile below can read this app's parameters,
  # and IMDSv1 hands those credentials to anything that can make an HTTP request
  # from the box -- which, on a machine whose whole job is running a browser
  # against a hostile page, is a category of request that happens constantly.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2 # 2, not 1: a container needs one extra hop
  }

  # k3s, ingress-nginx, cert-manager and the namespace. Everything after that is
  # `kubectl apply` from the pipeline. See scripts/k3s-bootstrap.sh in the
  # linkedout repository -- kept there rather than inlined here, because it is
  # long, it is tested by running it, and Terraform replaces the instance on any
  # change to user_data.
  user_data_replace_on_change = false
  user_data                   = file("${path.module}/linkedout-userdata.sh")

  tags = merge(local.linkedout_tags, { Name = "linkedout" })

  lifecycle {
    # The AMI moves as Canonical publishes; a plan proposing to rebuild the box
    # every month is a plan people stop reading.
    ignore_changes = [ami]
  }
}

# A stable address, because it is in two DNS records and a WorkOS redirect URI.
resource "aws_eip" "linkedout" {
  instance = aws_instance.linkedout.id
  domain   = "vpc"
  tags     = local.linkedout_tags
}

resource "aws_security_group" "linkedout" {
  name        = "linkedout"
  description = "LinkedOut k3s node"
  vpc_id      = data.aws_vpc.default.id
  tags        = local.linkedout_tags
}

# 80 and 443 only. NO SSH RULE, DELIBERATELY.
#
# Access is SSM Session Manager, which needs no inbound port, no key to lose and
# no bastion -- and which is already how the dialer is reached. The alternative
# is an office IP in a security group, and this organisation has already had one
# change underneath it and break every path in at once.
resource "aws_vpc_security_group_ingress_rule" "linkedout_https" {
  security_group_id = aws_security_group.linkedout.id
  description       = "TLS"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "linkedout_http" {
  security_group_id = aws_security_group.linkedout.id
  description       = "ACME HTTP-01 and the redirect to 443"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "linkedout_out" {
  security_group_id = aws_security_group.linkedout.id
  description       = "Everything: ghcr, WorkOS, LinkedIn through the per-account proxy, SSM"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# ---- the instance's identity ------------------------------------------------

resource "aws_iam_role" "linkedout_instance" {
  name = "linkedout-instance"
  tags = local.linkedout_tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "linkedout_ssm" {
  role       = aws_iam_role.linkedout_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# AmazonSSMManagedInstanceCore grants ssm:GetParameter on "*", which is how a
# box belonging to one app comes to be able to read every other app's secrets.
# It happened here: the dialer could read ACRM's Supabase service role key.
#
# The managed policy cannot be narrowed, so this denies everything outside this
# app's own prefix. An explicit Deny beats any Allow, including a future one
# somebody attaches without reading this.
data "aws_iam_policy_document" "linkedout_parameter_fence" {
  statement {
    sid     = "OnlyOwnParameters"
    effect  = "Deny"
    actions = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    not_resources = [
      "arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:parameter/linkedout/*",
    ]
  }
}

resource "aws_iam_role_policy" "linkedout_parameter_fence" {
  name   = "linkedout-only-own-parameters"
  role   = aws_iam_role.linkedout_instance.id
  policy = data.aws_iam_policy_document.linkedout_parameter_fence.json
}

resource "aws_iam_instance_profile" "linkedout" {
  name = "linkedout-instance"
  role = aws_iam_role.linkedout_instance.name
  tags = local.linkedout_tags
}

# ---- Postgres ---------------------------------------------------------------
#
# Managed, and this is the one place the cheap option is wrong. The database
# holds the suppression list, which carries legal weight and CANNOT BE REBUILT:
# entries are HMACs of SUPPRESSION_DIGEST_KEY and the table stores digests rather
# than identifiers, so there is nothing left to re-derive a lost row from.
#
# Thirteen dollars a month buys automated backups and point-in-time recovery for
# the one dataset on this machine that cannot be recreated. Redis runs in the
# cluster (k8s/dev/redis.yaml) because queues and leases rebuild themselves.

resource "aws_security_group" "linkedout_data" {
  name        = "linkedout-data"
  description = "Postgres for LinkedOut; reachable from its node only"
  vpc_id      = data.aws_vpc.default.id
  tags        = local.linkedout_tags
}

resource "aws_vpc_security_group_ingress_rule" "linkedout_postgres" {
  security_group_id            = aws_security_group.linkedout_data.id
  description                  = "Postgres from the k3s node"
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.linkedout.id
}

resource "aws_db_subnet_group" "linkedout" {
  name       = "linkedout"
  subnet_ids = slice(sort(data.aws_subnets.default.ids), 0, 2)
  tags       = local.linkedout_tags
}

resource "aws_db_instance" "linkedout" {
  identifier     = "linkedout"
  engine         = "postgres"
  engine_version = "16"
  instance_class = "db.t4g.micro"

  allocated_storage     = 20
  max_allocated_storage = 100
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = "linkedout"
  username = "linkedout_root"
  # Generated by RDS and held in Secrets Manager. Never in this file, never a
  # plaintext input in state, never typed into a console.
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.linkedout.name
  vpc_security_group_ids = [aws_security_group.linkedout_data.id]
  publicly_accessible    = false

  backup_retention_period = 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "Mon:04:00-Mon:05:00"

  deletion_protection       = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "linkedout-final"

  auto_minor_version_upgrade = true

  # engine_version is "16" and RDS resolves it to a minor it then raises in the
  # maintenance window; without this every later plan proposes putting it back.
  lifecycle {
    ignore_changes = [engine_version]
  }

  tags = local.linkedout_tags
}

output "linkedout" {
  value = {
    instance_id = aws_instance.linkedout.id
    address     = aws_eip.linkedout.public_ip
    database    = aws_db_instance.linkedout.address
    # Where the generated master password lives. The application never uses this
    # login -- it connects as app_user, which scripts/rds-bootstrap.sql creates.
    master_secret = aws_db_instance.linkedout.master_user_secret[0].secret_arn

    portal = "https://linkedout.wezerostudio.com"
    api    = "https://api.linkedout.wezerostudio.com"

    dns = "Point both names at ${aws_eip.linkedout.public_ip} with A records."
  }
}
