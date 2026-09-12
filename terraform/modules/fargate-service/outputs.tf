output "alb_dns_name" { value = aws_lb.this.dns_name }
output "alb_zone_id" { value = aws_lb.this.zone_id }
output "ecr_repository_url" { value = aws_ecr_repository.this.repository_url }
output "service_name" { value = aws_ecs_service.this.name }
output "task_execution_role_arn" { value = aws_iam_role.execution.arn }
output "task_role_arn" { value = aws_iam_role.task.arn }

# Exposed so a second service can hang off the same balancer rather than paying
# for another one.
output "https_listener_arn" {
  value = var.certificate_arn == null ? null : aws_lb_listener.https[0].arn
}

output "alb_security_group_id" { value = aws_security_group.alb.id }

# Exposed so a datastore's security group can name the tasks allowed to reach
# it, rather than opening a port to the whole VPC.
output "task_security_group_id" { value = aws_security_group.task.id }
