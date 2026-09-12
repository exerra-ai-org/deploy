# One Fargate service behind an application load balancer.
#
# The placeholder image is deliberate. The pipeline registers a new task
# definition revision pointing at the image it just built, and Terraform must
# not fight it -- hence ignore_changes on task_definition below. The first
# deploy replaces this.

data "aws_region" "current" {}

locals {
  name = var.app
  tags = { ManagedBy = "terraform", App = var.app }
}

# ---- registry ---------------------------------------------------------------
resource "aws_ecr_repository" "this" {
  name                 = var.app
  image_tag_mutability = "IMMUTABLE" # a tag that can move makes "what is running" unanswerable
  force_delete         = false

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
      description  = "Keep the last 20 images; a rollback never reaches further back than that."
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 20 }
      action       = { type = "expire" }
    }]
  })
}

# ---- logs -------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${var.app}"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

# ---- roles ------------------------------------------------------------------
# Two roles, and the distinction matters. The execution role is used by the ECS
# agent to pull the image and fetch secrets *before* the container starts. The
# task role is what the application itself gets. Merging them hands the
# application the ability to read every secret it was ever started with.
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

# Only this app's own parameters, and only if it has any.
data "aws_iam_policy_document" "execution_secrets" {
  count = length(var.secret_arns) > 0 ? 1 : 0

  statement {
    actions   = ["ssm:GetParameters"]
    resources = values(var.secret_arns)
  }

  statement {
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${data.aws_region.current.name}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "execution_secrets" {
  count  = length(var.secret_arns) > 0 ? 1 : 0
  name   = "${var.app}-read-own-secrets"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_secrets[0].json
}

resource "aws_iam_role" "task" {
  name               = "${var.app}-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.task_assume.json
  tags               = local.tags
}

# ---- networking -------------------------------------------------------------
resource "aws_security_group" "alb" {
  name        = "${var.app}-alb"
  description = "Public ingress to ${var.app}"
  vpc_id      = var.vpc_id
  tags        = local.tags

  ingress {
    description = "HTTP, redirected to HTTPS when a certificate exists"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  dynamic "ingress" {
    for_each = var.certificate_arn == null ? [] : [1]
    content {
      description = "HTTPS"
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# The task accepts traffic from the load balancer and from nowhere else. This is
# what makes a public subnet acceptable: the task has a public address so it can
# reach ECR, but nothing on the internet can open a connection to it.
resource "aws_security_group" "task" {
  name        = "${var.app}-task"
  description = "${var.app} tasks; ingress from the load balancer only"
  vpc_id      = var.vpc_id
  tags        = local.tags

  ingress {
    description     = "From the load balancer"
    from_port       = var.container_port
    to_port         = var.container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ---- load balancer ----------------------------------------------------------
resource "aws_lb" "this" {
  name               = var.app
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.subnet_ids
  idle_timeout       = 300 # socket.io connections are long-lived; 60s would cut them
  tags               = local.tags
}

resource "aws_lb_target_group" "this" {
  name        = var.app
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip" # awsvpc networking gives each task its own ENI

  # The app is single-task today, but socket.io without a shared adapter needs a
  # client to keep hitting the same task once there is more than one.
  stickiness {
    type            = "lb_cookie"
    enabled         = true
    cookie_duration = 86400
  }

  health_check {
    path                = var.health_path
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  # A task being replaced should stop receiving traffic promptly; the default
  # 300s makes every deploy five minutes slower for no benefit here.
  deregistration_delay = 30

  tags = local.tags
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  # With a certificate, port 80 exists only to send people to 443.
  dynamic "default_action" {
    for_each = var.certificate_arn == null ? [] : [1]
    content {
      type = "redirect"
      redirect {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }

  dynamic "default_action" {
    for_each = var.certificate_arn == null ? [1] : []
    content {
      type             = "forward"
      target_group_arn = aws_lb_target_group.this.arn
    }
  }
}

resource "aws_lb_listener" "https" {
  count             = var.certificate_arn == null ? 0 : 1
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}

# ---- the service ------------------------------------------------------------
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
    name = var.app
    # Placeholder. The pipeline registers a revision pointing at the real image;
    # ignore_changes on the service below stops Terraform reverting it.
    image     = "public.ecr.aws/nginx/nginx:alpine"
    essential = true

    portMappings = [{ containerPort = var.container_port, protocol = "tcp" }]

    environment = [for k, v in var.environment : { name = k, value = v }]
    secrets     = [for k, v in var.secret_arns : { name = k, valueFrom = v }]

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
    subnets         = var.subnet_ids
    security_groups = [aws_security_group.task.id]
    # Required without a NAT: this is how the task reaches ECR and Parameter
    # Store. Inbound is still closed by the security group.
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.this.arn
    container_name   = var.app
    container_port   = var.container_port
  }

  # Give a new task time to pass its health check before the balancer counts it
  # as failed. A Nest app connecting to Supabase on boot needs more than the
  # default zero.
  health_check_grace_period_seconds = 60

  # See variables.tf. Defaults are ECS's own overlapping rollout; 0/100 makes a
  # deploy stop the old task first, for services where two at once is a defect.
  deployment_minimum_healthy_percent = var.deployment_minimum_healthy_percent
  deployment_maximum_percent         = var.deployment_maximum_percent

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  depends_on = [aws_lb_listener.http]

  lifecycle {
    # The pipeline owns which revision runs, and how many. Terraform owns
    # everything else. Without this, the next apply would put the nginx
    # placeholder back.
    ignore_changes = [task_definition, desired_count]
  }

  tags = local.tags
}
