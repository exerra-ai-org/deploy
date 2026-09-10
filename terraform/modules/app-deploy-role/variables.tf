variable "app" {
  description = "App name. Decides the role name, the S3 prefix, the ECR repository and the App tag."
  type        = string
}

variable "sub_prefix" {
  description = <<-EOT
    The OIDC subject prefix for this app's repository, verbatim, without the
    trailing ":environment:<env>".

    Stored rather than constructed because the format is a per-repository
    property and is not uniform across an organisation. Repositories created
    after 15 July 2026 carry organisation and repository ids
    ("repo:org@123/repo@456"); older ones do not ("repo:org/repo"). Building
    this string from a template leaves the odd repository out failing at
    assume-role, alone, after everything else works.
  EOT
  type        = string
}

variable "environment" {
  description = "GitHub environment name. Part of the subject, so it decides which account a token can open."
  type        = string
}

variable "lane" {
  description = "ssm for a release onto an EC2 instance, ecs for an image onto Fargate."
  type        = string
  validation {
    condition     = contains(["ssm", "ecs"], var.lane)
    error_message = "lane must be ssm or ecs."
  }
}

variable "oidc_provider_arn" {
  type = string
}

variable "artifact_bucket" {
  description = "Shared release bucket. Each app is confined to its own prefix inside it."
  type        = string
}

variable "workflow_refs" {
  description = <<-EOT
    Fully qualified refs of the reusable workflows allowed to assume this role.

    Branches, not tags. The job_workflow_ref claim carries the ref the caller
    actually used, so callers and this list must agree; and a tag is movable by
    anyone with push, which makes a tag-pinned trust policy a pin in name only.
  EOT
  type        = list(string)
}

variable "permissions_boundary_arn" {
  type    = string
  default = null
}

variable "deploy_group_tag" {
  description = "Value of the DeployGroup tag identifying instances this platform manages."
  type        = string
  default     = "exerra"
}

variable "ecs_cluster_name" {
  description = "Null omits every ECS and iam:PassRole permission, which is the right default until a cluster exists."
  type        = string
  default     = null
}

variable "ecr_namespace" {
  description = "Optional prefix on the ECR repository name."
  type        = string
  default     = ""
}

variable "task_role_arns" {
  description = "Exactly the roles this app's tasks run as. Never widened: iam:PassRole is what turns 'can deploy' into 'can become anything'."
  type        = list(string)
  default     = []
}
