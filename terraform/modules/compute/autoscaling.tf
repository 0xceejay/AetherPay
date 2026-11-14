# The three metrics the alarms read: ECS CPU and memory for this service, and visible
# messages in the ingestion queue.
locals {
  scaling_metrics = {
    cpu = {
      namespace   = "AWS/ECS"
      metric_name = "CPUUtilization"
      dimensions = {
        ClusterName = aws_ecs_cluster.this.name
        ServiceName = aws_ecs_service.app.name
      }
    }
    memory = {
      namespace   = "AWS/ECS"
      metric_name = "MemoryUtilization"
      dimensions = {
        ClusterName = aws_ecs_cluster.this.name
        ServiceName = aws_ecs_service.app.name
      }
    }
    queue = {
      namespace   = "AWS/SQS"
      metric_name = "ApproximateNumberOfMessagesVisible"
      dimensions = {
        QueueName = element(reverse(split(":", var.ingestion_queue.arn)), 0)
      }
    }
  }
}

# Registers the service's desired count as a scalable target, bounded by the minimum and
# maximum capacity.
resource "aws_appautoscaling_target" "this" {
  min_capacity       = var.capacity.min
  max_capacity       = var.capacity.max
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.app.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"

  tags = local.common_tags
}

# Step policy that adds one task when the scale-out alarm fires. Its cooldown is the
# shorter scale_out_cooldown.
resource "aws_appautoscaling_policy" "scale_out" {
  name               = "${local.name_prefix}-scale-out"
  policy_type        = "StepScaling"
  resource_id        = aws_appautoscaling_target.this.resource_id
  scalable_dimension = aws_appautoscaling_target.this.scalable_dimension
  service_namespace  = aws_appautoscaling_target.this.service_namespace

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = var.scaling.scale_out_cooldown
    metric_aggregation_type = "Maximum"

    step_adjustment {
      metric_interval_lower_bound = 0
      scaling_adjustment          = 1
    }
  }
}

# Step policy that removes one task when the scale-in alarm fires. Its cooldown is the
# longer scale_in_cooldown.
resource "aws_appautoscaling_policy" "scale_in" {
  name               = "${local.name_prefix}-scale-in"
  policy_type        = "StepScaling"
  resource_id        = aws_appautoscaling_target.this.resource_id
  scalable_dimension = aws_appautoscaling_target.this.scalable_dimension
  service_namespace  = aws_appautoscaling_target.this.service_namespace

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = var.scaling.scale_in_cooldown
    metric_aggregation_type = "Maximum"

    step_adjustment {
      metric_interval_upper_bound = 0
      scaling_adjustment          = -1
    }
  }
}

# Any high signal can add a task without waiting for the other two.
resource "aws_cloudwatch_metric_alarm" "scale_out" {
  alarm_name          = "${local.name_prefix}-scale-out"
  alarm_description   = "Add capacity when CPU, memory, or visible ingestion backlog exceeds its configured threshold."
  comparison_operator = "GreaterThanThreshold"
  threshold           = 1
  evaluation_periods  = var.scaling.scale_out_periods
  datapoints_to_alarm = var.scaling.scale_out_periods
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_appautoscaling_policy.scale_out.arn]

  metric_query {
    id          = "pressure"
    expression  = "MAX([cpu/${var.scaling.cpu_scale_out},memory/${var.scaling.memory_scale_out},queue/${var.scaling.queue_scale_out}])"
    label       = "Scale-out pressure"
    return_data = true
  }

  dynamic "metric_query" {
    for_each = local.scaling_metrics

    content {
      id          = metric_query.key
      return_data = false

      metric {
        namespace   = metric_query.value.namespace
        metric_name = metric_query.value.metric_name
        dimensions  = metric_query.value.dimensions
        period      = 60
        stat        = "Average"
      }
    }
  }

  tags = local.common_tags
}

# All three signals need a longer quiet window before a task is removed.
# Missing samples hold pressure at one. One extra slot allows for reporting lag.
resource "aws_cloudwatch_metric_alarm" "scale_in" {
  alarm_name          = "${local.name_prefix}-scale-in"
  alarm_description   = "Remove capacity after the configured number of quiet CPU, memory, and ingestion-backlog samples, with one extra evaluation slot for reporting lag. Missing samples do not count as quiet."
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  evaluation_periods  = var.scaling.scale_in_periods + 1
  datapoints_to_alarm = var.scaling.scale_in_periods
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_appautoscaling_policy.scale_in.arn]

  metric_query {
    id          = "pressure"
    expression  = "MAX([FILL(cpu,${var.scaling.cpu_scale_in})/${var.scaling.cpu_scale_in},FILL(memory,${var.scaling.memory_scale_in})/${var.scaling.memory_scale_in},FILL(queue,${var.scaling.queue_scale_in})/${var.scaling.queue_scale_in}])"
    label       = "Scale-in pressure"
    return_data = true
  }

  dynamic "metric_query" {
    for_each = local.scaling_metrics

    content {
      id          = metric_query.key
      return_data = false

      metric {
        namespace   = metric_query.value.namespace
        metric_name = metric_query.value.metric_name
        dimensions  = metric_query.value.dimensions
        period      = 60
        stat        = "Average"
      }
    }
  }

  tags = local.common_tags
}
