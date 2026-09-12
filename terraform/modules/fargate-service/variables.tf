variable "app" { type = string }
variable "cluster_name" { type = string }
variable "vpc_id" { type = string }

variable "subnet_ids" {
  description = <<-EOT
    Public subnets, with assign_public_ip on the service.

    Deliberate: a Fargate task in a private subnet needs a NAT to pull from ECR,
    and a managed NAT gateway is about 35 dollars a month -- several times the
    cost of the task it exists to serve. The task is not reachable from the
    internet regardless, because its security group only accepts traffic from
    the load balancer.
  EOT
  type        = list(string)
}

variable "container_port" {
  type    = number
  default = 3005
}

variable "health_path" {
  type    = string
  default = "/health"
}

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
  default = 1
}

variable "secret_arns" {
  description = "SSM parameter ARNs injected as environment variables: { ENV_NAME = arn }."
  type        = map(string)
  default     = {}
}

variable "environment" {
  description = "Plain environment variables. Never secrets: these are visible in the task definition."
  type        = map(string)
  default     = {}
}

variable "certificate_arn" {
  description = "ACM certificate for the HTTPS listener. Null serves plain HTTP on 80 only."
  type        = string
  default     = null
}

variable "log_retention_days" {
  type    = number
  default = 30
}

# ---- deployment shape -------------------------------------------------------
# Defaults are ECS's own: start a replacement before draining the old task, so a
# deploy causes no downtime. Correct for a stateless web tier and WRONG for a
# service that must never run twice at once.
#
# LinkedOut's API is the second kind. It runs the campaign dispatcher on a timer
# and holds per-account BullMQ consumers, so two instances means two dispatchers
# independently deciding the same enrolment is ready -- and the failure is a
# duplicate LinkedIn invitation to a real person, which cannot be withdrawn. Its
# Kubernetes manifest says `strategy: Recreate` for exactly this reason; 0/100
# here is that same decision in ECS terms.
variable "deployment_minimum_healthy_percent" {
  description = "0 drains the old task before starting the new one. Use it when two instances must never overlap."
  type        = number
  default     = 100
}

variable "deployment_maximum_percent" {
  description = "100 forbids a second task during a deploy. Pair with minimum 0, or the deploy cannot proceed at all."
  type        = number
  default     = 200
}
