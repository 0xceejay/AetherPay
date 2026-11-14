# ARN of the ECS cluster.
output "cluster_arn" {
  description = "ECS cluster ARN."
  value       = aws_ecs_cluster.this.arn
}

# Name of the ingestor service, for deployment and operations commands.
output "service_name" {
  description = "Ingestor service name for deployment and operational commands."
  value       = aws_ecs_service.app.name
}

# ARN of the current task definition revision.
output "task_definition_arn" {
  description = "Current ingestor task-definition revision ARN."
  value       = aws_ecs_task_definition.app.arn
}

# ARNs of the execution and task roles. The security module needs the task role for its
# secret policies.
output "role_arns" {
  description = "Separate execution and application role ARNs."
  value = {
    execution = aws_iam_role.execution.arn
    task      = aws_iam_role.task.arn
  }
}
