# ARN and URL of the ingestion queue. Compute uses them for IAM, the task environment
# and the queue-depth alarms.
output "ingestion_queue" {
  description = "Actual ingestion queue ARN and URL for compute, scaling, and endpoint policies."
  value = {
    arn = aws_sqs_queue.ingestion.arn
    url = aws_sqs_queue.ingestion.url
  }
}

# ARN and URL of the dead-letter queue.
output "dead_letter_queue" {
  description = "Dead-letter queue ARN and URL for failed ingestion messages."
  value = {
    arn = aws_sqs_queue.dead_letter.arn
    url = aws_sqs_queue.dead_letter.url
  }
}
