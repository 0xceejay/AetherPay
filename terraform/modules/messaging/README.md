# AetherPay messaging

Creates one standard SQS ingestion queue with SSE-SQS encryption, 20-second
long polling, and four-day retention, plus its dead-letter queue (DLQ).
`visibility_timeout_seconds` defaults to 60 seconds; set it above the
application's expected processing time or extend visibility while processing.

The `ingestion_queue` output contains the queue's actual ARN and URL. Staging
passes it to compute for application configuration, exact-resource IAM and
endpoint permissions, and queue-depth scaling. The queue does not depend on
those consumers, so their policies can safely reference its output.

After `max_receive_count` failed receives (default 5), SQS moves a message to the
DLQ, which retains it for 14 days. Without this, a poison message would return
to the ingestion backlog after every visibility timeout for the full four-day
retention, holding queue-depth scaling high and blocking scale-in. A redrive-allow
policy accepts messages only from the ingestion queue. The DLQ is encrypted the
same way.

Adding ingestor tasks does not drain a DLQ, so it does not drive scaling. Investigate
the failure, fix the handler, then use an SQS redrive back to the ingestion queue. The
`dead_letter_queue` output exposes the DLQ ARN and URL.

Standard SQS can deliver duplicates or messages out of order. Payment handlers
must process messages idempotently, including messages redriven from the DLQ.
Encryption uses SQS-owned keys; the separate secrets module supplies the
assessment's customer-managed encryption for credentials and signing keys. See
[SQS queue attributes](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/APIReference/API_CreateQueue.html)
and [dead-letter queues](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-dead-letter-queues.html).

[GitHub Actions](../../../.github/workflows) runs the automated checks.
