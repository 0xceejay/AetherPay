# Queue name (<project>-<environment>-ingestion) and the standard tags.
locals {
  queue_name = "${var.project_name}-${var.environment}-ingestion"
  common_tags = merge(var.tags, {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  })
}

# Main ingestion queue. Messages are encrypted with SQS-managed keys, consumers long
# poll for up to 20 seconds, and messages are kept for 4 days (345600 seconds). After
# max_receive_count failed receives a message moves to the dead-letter queue.
resource "aws_sqs_queue" "ingestion" {
  name                       = local.queue_name
  fifo_queue                 = false
  sqs_managed_sse_enabled    = true
  receive_wait_time_seconds  = 20
  message_retention_seconds  = 345600
  visibility_timeout_seconds = var.visibility_timeout_seconds

  # Poison messages leave the ingestion backlog after repeated failed receives,
  # so they cannot hold queue-depth scaling high or block scale-in.
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dead_letter.arn
    maxReceiveCount     = var.max_receive_count
  })

  tags = local.common_tags
}

# Retention exceeds the source queue's so failed messages remain for investigation
# and controlled redrive.
resource "aws_sqs_queue" "dead_letter" {
  name                      = "${local.queue_name}-dlq"
  fifo_queue                = false
  sqs_managed_sse_enabled   = true
  message_retention_seconds = 1209600

  tags = local.common_tags
}

# A separate resource avoids a cycle between the two queues.
resource "aws_sqs_queue_redrive_allow_policy" "dead_letter" {
  queue_url = aws_sqs_queue.dead_letter.id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.ingestion.arn]
  })
}
