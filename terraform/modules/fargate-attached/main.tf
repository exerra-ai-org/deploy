data "aws_region" "current" {}

locals {
  tags = { ManagedBy = "terraform", App = var.app }
}

resource "aws_ecr_repository" "this" {
  name                 = var.app
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration {
    scan_on_push = true
  }
  tags = local.tags
}

resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last 20 images."
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 20 }
      action       = { type = "expire" }
    }]
  })
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${var.app}"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

data "aws_iam_policy_document" "task_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${var.app}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.task_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "task" {
  name               = "${var.app}-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.task_assume.json
  tags               = local.tags
}

# Reachable from the shared load balancer and nothing else, which is what makes
# a public subnet acceptable: the task needs a public address to pull from ECR,
# but no inbound path exists from the internet.
resource "aws_security_group" "task" {
  name        = "${var.app}-task"
  description = "${var.app} tasks; ingress from the shared load balancer only"
  vpc_id      = var.vpc_id
  tags        = local.tags

  ingress {
    from_port       = var.container_port
    to_port         = var.container_port
    protocol        = "tcp"
    security_groups = [var.alb_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb_target_group" "this" {
  name        = var.app
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = var.health_path
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  deregistration_delay = 30
  tags                 = local.tags
}

# A second certificate on the existing listener. Listeners hold many, and SNI
# picks between them, so both hostnames share one balancer.
resource "aws_lb_listener_certificate" "this" {
  listener_arn    = var.listener_arn
  certificate_arn = var.certificate_arn
}

# Host-based, not path-based. The API has no route prefix -- its routes sit at
# the root -- and an ALB can route on a path but cannot rewrite one, so two apps
# cannot share a hostname here.
resource "aws_lb_listener_rule" "this" {
  listener_arn = var.listener_arn
  priority     = var.rule_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }

  condition {
    host_header {
      values = [var.host_header]
    }
  }

  tags = local.tags
}

resource "aws_ecs_task_definition" "this" {
  family                   = var.app
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn
  tags                     = local.tags

  container_definitions = jsonencode([{
    name         = var.app
    image        = "public.ecr.aws/nginx/nginx:alpine" # replaced by the first deploy
    essential    = true
    portMappings = [{ containerPort = var.container_port, protocol = "tcp" }]
    environment  = [for k, v in var.environment : { name = k, value = v }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.this.name
        "awslogs-region"        = data.aws_region.current.name
        "awslogs-stream-prefix" = var.app
      }
    }
  }])
}

resource "aws_ecs_service" "this" {
  name            = "${var.app}-service"
  cluster         = var.cluster_name
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [aws_security_group.task.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.this.arn
    container_name   = var.app
    container_port   = var.container_port
  }

  health_check_grace_period_seconds = 60

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  depends_on = [aws_lb_listener_rule.this]

  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }

  tags = local.tags
}
