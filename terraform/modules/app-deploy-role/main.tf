# One deploy role for one app.
#
# The name is a convention the central workflow relies on rather than a value
# any repository has to be told:
#
#   arn:aws:iam::<account>:role/exerra-deploy-<app>-<environment>
#
# That is what makes a role per app cost no per-repository configuration. The
# workflow derives the app from github.repository, and the ARN follows.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account  = data.aws_caller_identity.current.account_id
  region   = data.aws_region.current.name
  name     = "exerra-deploy-${var.app}-${var.environment}"
  ecr_repo = var.ecr_namespace == "" ? var.app : "${var.ecr_namespace}/${var.app}"
}

# Three conditions, and all three are load-bearing.
#
#   aud               - the audience, or any GitHub token anywhere would do.
#   sub               - one repository, one environment. The environment half is
#                       why each repository needs the environment object created:
#                       without it the claim reads :ref:refs/heads/main instead
#                       and matches nothing here.
#   job_workflow_ref  - the code path. Without it a repository could write its
#                       own workflow and use this role however it liked; the
#                       registry that maps repository to app lives in the central
#                       workflow, so pinning the workflow is what makes the
#                       registry a boundary rather than a convention.
data "aws_iam_policy_document" "trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${var.sub_prefix}:environment:${var.environment}"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:job_workflow_ref"
      values   = var.workflow_refs
    }
  }
}

resource "aws_iam_role" "this" {
  name                 = local.name
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  permissions_boundary = var.permissions_boundary_arn
  max_session_duration = 3600

  tags = {
    ManagedBy   = "terraform"
    App         = var.app
    Environment = var.environment
    Lane        = var.lane
  }
}

data "aws_iam_policy_document" "permissions" {
  # ---- artefacts ----------------------------------------------------------
  statement {
    sid       = "WriteOwnReleases"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["arn:aws:s3:::${var.artifact_bucket}/${var.app}/releases/*"]
  }

  # Grants nothing the role cannot already reach, and is worth having anyway:
  # without ListBucket, S3 answers 403 for a key that is simply absent, so
  # "the artefact never uploaded" and "the role is wrong" are indistinguishable
  # at the exact moment you need to tell them apart.
  statement {
    sid       = "SeeOwnReleases"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.artifact_bucket}"]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${var.app}/releases/*"]
    }
  }

  # ---- the SSM lane -------------------------------------------------------
  dynamic "statement" {
    for_each = var.lane == "ssm" ? [1] : []
    content {
      sid       = "RunShellScript"
      effect    = "Allow"
      actions   = ["ssm:SendCommand"]
      resources = ["arn:aws:ssm:${local.region}::document/AWS-RunShellScript"]
    }
  }

  # Both instance ARN shapes, deliberately.
  #
  # IAM was observed evaluating arn:aws:ssm:...:managed-instance/i-... for an
  # instance whose agent had registered under its EC2 identity. A policy
  # carrying only the ec2:instance form produced "no identity-based policy
  # allows the ssm:SendCommand action", naming neither shape, and cost three
  # deploys to diagnose.
  #
  # The tag condition is the actual boundary: this role can only reach instances
  # tagged with its own app, so the second ARN form widens nothing.
  dynamic "statement" {
    for_each = var.lane == "ssm" ? [1] : []
    content {
      sid     = "OnlyOwnInstances"
      effect  = "Allow"
      actions = ["ssm:SendCommand"]
      resources = [
        "arn:aws:ec2:${local.region}:${local.account}:instance/*",
        "arn:aws:ssm:${local.region}:${local.account}:managed-instance/*",
      ]

      condition {
        test     = "StringEquals"
        variable = "ssm:resourceTag/App"
        values   = [var.app]
      }

      condition {
        test     = "StringEquals"
        variable = "ssm:resourceTag/DeployGroup"
        values   = [var.deploy_group_tag]
      }
    }
  }

  # Reading back what a command did. Unscoped because a command id is not
  # guessable and the reply carries only this role's own output.
  dynamic "statement" {
    for_each = var.lane == "ssm" ? [1] : []
    content {
      sid       = "ReadCommandResults"
      effect    = "Allow"
      actions   = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations"]
      resources = ["*"]
    }
  }

  # ---- the ECS lane -------------------------------------------------------
  dynamic "statement" {
    for_each = var.lane == "ecs" ? [1] : []
    content {
      sid       = "EcrAuth"
      effect    = "Allow"
      actions   = ["ecr:GetAuthorizationToken"]
      resources = ["*"]
    }
  }

  dynamic "statement" {
    for_each = var.lane == "ecs" ? [1] : []
    content {
      sid    = "PushOwnImages"
      effect = "Allow"
      actions = [
        "ecr:BatchCheckLayerAvailability",
        "ecr:CompleteLayerUpload",
        "ecr:InitiateLayerUpload",
        "ecr:PutImage",
        "ecr:UploadLayerPart",
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer",
        "ecr:DescribeImages",
      ]
      resources = ["arn:aws:ecr:${local.region}:${local.account}:repository/${local.ecr_repo}"]
    }
  }

  dynamic "statement" {
    for_each = var.lane == "ecs" && var.ecs_cluster_name != null ? [1] : []
    content {
      sid       = "DeployOwnService"
      effect    = "Allow"
      actions   = ["ecs:UpdateService", "ecs:DescribeServices"]
      resources = ["arn:aws:ecs:${local.region}:${local.account}:service/${var.ecs_cluster_name}/${var.app}-service"]
    }
  }

  dynamic "statement" {
    for_each = var.lane == "ecs" && var.ecs_cluster_name != null ? [1] : []
    content {
      sid       = "RegisterTaskDefinitions"
      effect    = "Allow"
      actions   = ["ecs:RegisterTaskDefinition", "ecs:DescribeTaskDefinition"]
      resources = ["*"] # neither action supports resource-level permissions
    }
  }

  # The one permission that converts "can deploy" into "can become anything in
  # the account". Named roles only, and only to ECS. Never "*", and never
  # without the PassedToService condition.
  dynamic "statement" {
    for_each = var.lane == "ecs" && length(var.task_role_arns) > 0 ? [1] : []
    content {
      sid       = "PassTaskRolesToEcsOnly"
      effect    = "Allow"
      actions   = ["iam:PassRole"]
      resources = var.task_role_arns

      condition {
        test     = "StringEquals"
        variable = "iam:PassedToService"
        values   = ["ecs-tasks.amazonaws.com"]
      }
    }
  }
}

resource "aws_iam_role_policy" "this" {
  name   = "${local.name}-access"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.permissions.json
}
