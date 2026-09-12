# ACRM on Fargate, behind a load balancer.
#
# Public subnets in the default VPC, because the alternative is a NAT gateway at
# roughly 35 dollars a month to serve a task costing about nine. The task is not
# reachable from the internet: its security group accepts traffic from the load
# balancer only.

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

module "acrm" {
  source = "../../modules/fargate-service"

  app          = "acrm"
  cluster_name = var.ecs_cluster_name
  vpc_id       = data.aws_vpc.default.id

  # Two AZs is the minimum an application load balancer accepts.
  subnet_ids = slice(sort(data.aws_subnets.default.ids), 0, 2)

  container_port = 3005
  # /healthz/ready, not /health.
  #
  # The controller is @Controller('healthz') with a bare @Get() for liveness and
  # @Get('ready') for readiness. Readiness is the one a load balancer wants: it
  # checks the database and the dialer, so a task that is running but cannot
  # reach either stops receiving traffic instead of accepting it and failing.
  #
  # /health exists nowhere in this app. It appears in watchdog.service.ts, but
  # that is ACRM calling the *dialer's* endpoint, which is what made grepping
  # for "health" misleading.
  health_path = "/healthz/ready"

  # 0.25 vCPU / 0.5 GB, the smallest Fargate size. About 9 dollars a month.
  # Raise it when the app tells you to, not before.
  cpu    = 256
  memory = 512

  # Zero until the first real image exists.
  #
  # The task definition ships an nginx placeholder, which has no /health. Start
  # at one and the target group marks it unhealthy, ECS replaces it, and the
  # loop repeats -- a console full of red and a slow drip of Fargate charges for
  # a service that was never going to come up. The pipeline raises this after it
  # pushes the first image.
  #
  # ignore_changes on desired_count means this value is the starting point, not
  # a ceiling: scaling later is not fought by the next apply.
  desired_count = 0

  environment = {
    NODE_ENV = "production"
  }

  # Filled in once the parameters exist. Names here become environment
  # variables; the execution role is scoped to exactly these ARNs.
  secret_arns = var.acrm_secret_arns

  # No certificate yet, so the balancer serves plain HTTP on 80. Add an ACM
  # certificate and this becomes a redirect to 443.
  certificate_arn = var.acrm_certificate_arn
}

output "acrm" {
  value = {
    alb            = module.acrm.alb_dns_name
    ecr            = module.acrm.ecr_repository_url
    service        = module.acrm.service_name
    task_role      = module.acrm.task_role_arn
    execution_role = module.acrm.task_execution_role_arn
  }
}

# ---- the frontend -----------------------------------------------------------
# React Router with ssr: true, so a Node service rather than a static bundle.
# Attached to ACRM's existing load balancer: a host rule sends
# app.acrm.wezerostudio.com here and everything else keeps reaching the API.
module "acrm_frontend" {
  source = "../../modules/fargate-attached"

  app          = "acrm-frontend"
  cluster_name = var.ecs_cluster_name
  vpc_id       = data.aws_vpc.default.id
  subnet_ids   = slice(sort(data.aws_subnets.default.ids), 0, 2)

  listener_arn          = module.acrm.https_listener_arn
  alb_security_group_id = module.acrm.alb_security_group_id
  certificate_arn       = var.acrm_frontend_certificate_arn
  host_header           = "app.acrm.wezerostudio.com"
  rule_priority         = 100

  container_port = 3000
  # react-router-serve has no health endpoint of its own; the app's root is the
  # thing a browser asks for anyway, so a 200 there is the check that matters.
  health_path = "/"

  cpu           = 256
  memory        = 512
  desired_count = 0

  environment = {
    NODE_ENV = "production"
  }
}

output "acrm_frontend" {
  value = {
    ecr     = module.acrm_frontend.ecr_repository_url
    service = module.acrm_frontend.service_name
    url     = "https://app.acrm.wezerostudio.com"
  }
}
