output "role_arns" {
  description = "One per app. The central workflow derives these rather than being told them; this is for checking the convention held."
  value       = { for k, m in module.deploy_role : k => m.role_arn }
}
