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
  health_path    = "/health"

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
