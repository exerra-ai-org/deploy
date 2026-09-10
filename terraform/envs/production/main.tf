# Deploy roles for the production environment.
#
#   terraform init -backend-config=backend.hcl
#   terraform plan
#
# One role per app. Adding an app means adding a line to locals.apps here and a
# line to the registry in .github/workflows/*.yml, in the same pull request --
# they have to agree, and keeping them in one repository is what makes that
# reviewable rather than a thing somebody remembers.

terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    key          = "deploy-roles/production.tfstate"
    use_lockfile = true # S3 native locking; needs Terraform 1.11+
  }
}

provider "aws" {
  region = var.aws_region

  # Refuses to run against the wrong account. Cheap insurance once two nearly
  # identical roots exist side by side.
  allowed_account_ids = [var.aws_account_id]
}

locals {
  # sub_prefix is verbatim from `gh api repos/<org>/<repo>/actions/oidc/customization/sub`.
  #
  # Not constructed. Five of these repositories carry organisation and
  # repository ids because they were created after 15 July 2026; Truck-Engine
  # predates that and does not. Templating one form across all six leaves
  # trucking failing at assume-role by itself, after everything else works, with
  # an error that names nothing.
  apps = {
    dialer = {
      lane       = "ssm"
      sub_prefix = "repo:exerra-ai-org@226608819/dialer@1335212327"
    }
    acrm = {
      lane       = "ecs"
      sub_prefix = "repo:exerra-ai-org@226608819/ACRM@1335280218"
    }
    franchiseos = {
      lane       = "ecs"
      sub_prefix = "repo:exerra-ai-org@226608819/franchiseOS@1361374692"
    }
    linkedout = {
      lane       = "ecs"
      sub_prefix = "repo:exerra-ai-org@226608819/linkedout@1337194820"
    }
    rusrus = {
      lane       = "ecs"
      sub_prefix = "repo:exerra-ai-org@226608819/rusrus@1357186056"
    }
    trucking = {
      lane       = "ecs"
      sub_prefix = "repo:exerra-ai-org/Truck-Engine" # old format, see above
    }
  }

  # Branches, not tags. job_workflow_ref carries the ref the caller used, so
  # callers must write @main for these to match -- and a tag would be a pin that
  # anyone with push can move.
  workflow_refs = [
    "exerra-ai-org/deploy/.github/workflows/ecs.yml@refs/heads/main",
    "exerra-ai-org/deploy/.github/workflows/ssm-release.yml@refs/heads/main",
  ]
}

module "deploy_role" {
  source   = "../../modules/app-deploy-role"
  for_each = local.apps

  app         = each.key
  lane        = each.value.lane
  sub_prefix  = each.value.sub_prefix
  environment = var.environment

  oidc_provider_arn        = var.oidc_provider_arn
  artifact_bucket          = var.artifact_bucket
  workflow_refs            = local.workflow_refs
  permissions_boundary_arn = var.permissions_boundary_arn
  deploy_group_tag         = var.deploy_group_tag
  ecs_cluster_name         = var.ecs_cluster_name
  ecr_namespace            = var.ecr_namespace
  task_role_arns           = var.task_role_arns
}
