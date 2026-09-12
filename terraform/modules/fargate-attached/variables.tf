# A second service on a load balancer somebody else already created.
#
# Separate from fargate-service because that module owns an ALB. Two apps behind
# one balancer is the point here: an ALB is 16 dollars a month and a Fargate task
# is nine, so a second balancer would cost more than the thing it serves.

variable "app" { type = string }
variable "cluster_name" { type = string }
variable "vpc_id" { type = string }
variable "subnet_ids" { type = list(string) }

variable "listener_arn" {
  description = "The HTTPS listener to hang a host rule off."
  type        = string
}

variable "alb_security_group_id" {
  description = "Allowed to reach the tasks. Nothing else is."
  type        = string
}

variable "host_header" {
  description = "The hostname this service answers on."
  type        = string
}

variable "certificate_arn" {
  description = "Attached to the shared listener. A listener holds several certificates, which is why one balancer can serve both names."
  type        = string
}

variable "container_port" { type = number }
variable "health_path" { type = string }
variable "rule_priority" { type = number }

variable "cpu" {
  type    = number
  default = 256
}
variable "memory" {
  type    = number
  default = 512
}
variable "desired_count" {
  type    = number
  default = 0
}
variable "log_retention_days" {
  type    = number
  default = 30
}
variable "environment" {
  type    = map(string)
  default = {}
}

# Named like fargate-service's, because an attached service needs credentials
# for the same reasons a standalone one does. LinkedOut's portal is the case
# that forced it: it holds a WorkOS API key and a cookie-encryption password,
# neither of which belongs in `environment`, which renders in plain text in
# every console and every describe-task-definition.
variable "secret_arns" {
  description = "SSM parameter ARNs as { ENV_NAME = arn }. The execution role is scoped to exactly these."
  type        = map(string)
  default     = {}
}
