variable "aws_account_id" {
  description = "Guarded by allowed_account_ids, so a wrong value fails before anything is created."
  type        = string
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "environment" {
  type    = string
  default = "production"
}

variable "oidc_provider_arn" {
  description = "arn:aws:iam::<account>:oidc-provider/token.actions.githubusercontent.com"
  type        = string
}

variable "artifact_bucket" {
  type = string
}

variable "permissions_boundary_arn" {
  description = "DeploymentPermissionsBoundary. Leave null only if the account has no boundary policy."
  type        = string
  default     = null
}

variable "deploy_group_tag" {
  type    = string
  default = "exerra"
}

variable "ecs_cluster_name" {
  description = "Null until a cluster exists here, which omits every ECS and iam:PassRole permission."
  type        = string
  default     = null
}

variable "ecr_namespace" {
  type    = string
  default = ""
}

variable "task_role_arns" {
  description = "The ECS task and task-execution roles, once they exist. Empty omits iam:PassRole entirely."
  type        = list(string)
  default     = []
}
