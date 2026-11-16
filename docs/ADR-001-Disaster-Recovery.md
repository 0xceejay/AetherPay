# ADR-001: Recover the ledger without split-brain writes

Status: Proposed, not deployed. Date: 2026-11-11.

## Context and recovery targets

At 02:15 UTC, primary Region A loses its networking and storage control planes and
drops 40% of packets. A may still renew its database lease while partner webhooks
to A time out. Partners retry, and sustained timeouts trigger payment-network
suspension, so the deadline is the suspension threshold, not A's total failure. A
reachable primary is not necessarily a safe leader. This design needs multi-Region
capability the current `us-east-1`-only project lacks, so the existing Terraform
cannot meet these targets alone.

| State | RPO | RTO |
| --- | --- | --- |
| Acknowledged ledger entries and webhook receipts | 0: acknowledge only after a cross-Region durable commit | 15 minutes, given a safe synchronous copy and surviving quorum |
| Event and settlement idempotency records | 0: same transaction as the ledger and outbox | Recovers with the ledger |
| Redis deduplication cache and sessions | Not replicated; total loss accepted, durable duplicate checks stay authoritative | 5 minutes to rebuild or reauthenticate |

Unacknowledged requests may have committed, and partners retry the same event ID.
Corrections append compensating ledger entries. Regional SQS and Redis are never
the ledger or the recovery authority.

## Decision and trade-offs

Use synchronous active-passive: one PostgreSQL writer with a warm standby. Regions
A, B, and C each run a Patroni-managed PostgreSQL node and an etcd voter. A and B
also run ingress and workers; C stores data only. Standbys that count toward
acknowledgement are outside the writer's Region. This needs self-managed
PostgreSQL, not RDS or Aurora.

Set Patroni `synchronous_mode=true`, `synchronous_mode_strict=true`,
`synchronous_node_count=1`, `check_timeline=true`, and PostgreSQL
`synchronous_commit=remote_apply`. Commit waits for local WAL durability and a
remote standby's durable replay. With no remote copy, writes block. Promotion
requires Patroni's recorded synchronous eligibility, not a recent lag sample.
See [PostgreSQL durability](https://www.postgresql.org/docs/current/runtime-config-wal.html)
and [Patroni replication](https://patroni.readthedocs.io/en/latest/replication_modes.html).

Asynchronous active-passive loses acknowledged writes on failover, which breaks
RPO 0. Active-active lets two Regions accept the same settlement. It reaches RPO 0
only through global consensus and a larger database and application migration.
Synchronous active-passive keeps PostgreSQL semantics but adds cross-Region
latency and blocks writes during a partition.

## Fencing and settlement safety

etcd needs 2 of 3 voters to grant or renew leadership. Configure Patroni `ttl=30`,
`loop_wait=5`, `retry_timeout=5`, `failsafe_mode=false`, and a tested Linux
watchdog with `mode=required`, `safety_margin=-1`. A leader that loses renewal
stops PostgreSQL, and the watchdog resets a stuck host before the lease expires. A
successor waits for confirmed release or expiry plus synchronous eligibility. DNS
changes do not fence a disconnected writer, so never delete the leader key or
force a manual failover. See [watchdog guarantees](https://patroni.readthedocs.io/en/latest/watchdog.html)
and [etcd partitions](https://etcd.io/docs/v3.6/op-guide/failures/).

Each event commits atomically with a unique event ID, payload fingerprint, ledger
entry, settlement ID, and outbox row. Dispatchers commit their claim synchronously
before sending. All settlement egress goes through an adapter that reads the leader
identity and the leader key's `create_revision` from etcd (linearizable) and
refuses dispatch while `/service/aetherpay/settlement/paused` exists. B and C can
write that key without A. If leadership is missing, mismatched, or unreadable,
dispatch is rejected, so A's in-memory queue cannot settle after it loses the
lease. This adapter is a required future application contract.

Every retry, including delayed requests from the old Region, uses the same
provider-enforced idempotency key. A pre-send check cannot cancel an in-flight
request, so unknown outcomes need same-key reconciliation. If the provider's
deduplication window is too short, quarantine them and stop settlement. See
[retry safety](https://aws.amazon.com/builders-library/making-retries-safe-with-idempotent-APIs/).

## Recovery without the primary control plane

Pre-create Route 53 ARC routing controls, health checks, and DNS failover records
(60-second TTL). Cache ARC's five regional cluster endpoints with their signing
Regions, and the control ARNs outside A. Keep operator sessions, mTLS access,
images, and secrets ready in B and C. Failover then uses only etcd/Patroni and ARC
data-plane APIs, with no primary IAM change, DNS edit, deployment, or console
lookup. If credentials have expired, use the prepared healthy-Region credential
path or halt. DNS does not close existing connections. See
[ARC preparation](https://docs.aws.amazon.com/r53recovery/latest/dg/route53-arc-best-practices.regional.html).

## First 30 minutes

The commands need future infrastructure. `/etc/aetherpay/dr.env` supplies
non-secret identifiers: `AWS_PROFILE`, `ETCD_B`, `ETCD_C`, `PATRONI_CFG`,
`ARC_ENDPOINT`, `ARC_REGION`, `RC_A`, `RC_B`, `PARTNER_HOST`, `REGION_B`, and
`QUEUE_B_URL`. etcd TLS, credentials, and the libpq service `ledger_b` are set up
separately. Patroni uses scope `aetherpay` and members `pg-a` and `pg-b`. A failed
gate stops progression.

02:15 to 02:18, declare and pause settlement. Freeze releases and automated
failback, then run from a host outside A:

```sh
. /etc/aetherpay/dr.env; export AWS_PROFILE
for i in $(seq 20); do curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 "https://$PARTNER_HOST/health"; done | sort | uniq -c
etcdctl --endpoints="$ETCD_B,$ETCD_C" endpoint health
etcdctl --endpoints="$ETCD_B,$ETCD_C" put /service/aetherpay/settlement/paused "$(date -u +%FT%TZ)"
etcdctl --endpoints="$ETCD_B,$ETCD_C" get /service/aetherpay/leader --write-out=json
patronictl -c "$PATRONI_CFG" show-config aetherpay
patronictl -c "$PATRONI_CFG" list aetherpay
```

Gate: probes confirm partner-facing failures, B and C have quorum, strict settings
are in place, settlement is paused, and B is healthy and synchronously eligible.
Ingestion continues; only dispatch stops.

02:18 to 02:23, transfer leadership. If A still holds its lease and answers
Patroni, switch over gracefully:

```sh
patronictl -c "$PATRONI_CFG" switchover aetherpay --primary pg-a --candidate pg-b --force
```

If A is unreachable, wait for automatic election and watchdog fencing. After a
timeout, check leader, sync, and roles before retrying. If A keeps renewing and
cannot transfer, leave settlement paused and do not force B up.

02:23 to 02:27, verify before rerouting. Repeat the quorum and leader checks, then:

```sh
psql 'service=ledger_b' -X -v ON_ERROR_STOP=1 -c 'SELECT pg_is_in_recovery();' -c 'SHOW synchronous_commit;' -c 'SHOW synchronous_standby_names;'
psql 'service=ledger_b' -X -v ON_ERROR_STOP=1 -c 'SELECT application_name, state, sync_state, replay_lsn FROM pg_stat_replication;'
```

Gate: B is the sole lease holder and not in recovery, A is demoted or fenced,
`remote_apply` is enforced, C streams synchronously, and the adapter rejects stale
claims. Replay one signed nonfinancial canary twice against B and require one
durable event and one sandbox settlement.

02:27 to 02:30, switch ingress through a reachable cached ARC endpoint:

```sh
aws route53-recovery-cluster update-routing-control-states --region "$ARC_REGION" --endpoint-url "$ARC_ENDPOINT" --update-routing-control-state-entries RoutingControlArn="$RC_A",RoutingControlState=Off RoutingControlArn="$RC_B",RoutingControlState=On
aws route53-recovery-cluster get-routing-control-state --region "$ARC_REGION" --endpoint-url "$ARC_ENDPOINT" --routing-control-arn "$RC_B"
```

If an endpoint fails, retry with another cached endpoint and Region, then read back
both controls. See [ARC endpoints](https://docs.aws.amazon.com/general/latest/gr/arc.html).

02:30 to 02:45, verify, reconcile, resume:

```sh
curl --fail --tlsv1.3 --tls-max 1.3 --max-time 10 "https://$PARTNER_HOST/health"
aws sqs get-queue-attributes --region "$REGION_B" --queue-url "$QUEUE_B_URL" --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible
psql 'service=ledger_b' -X -v ON_ERROR_STOP=1 -c 'SELECT count(*) FROM settlement_outbox WHERE state = $$unknown$$;'
etcdctl --endpoints="$ETCD_B,$ETCD_C" del /service/aetherpay/settlement/paused
```

Gates, in order: the health response reports Region B over TLS 1.3, B's queue
drains, and unknown settlement outcomes reach zero through same-key reconciliation.
Only then delete the pause key and ask partner operations to lift suspensions. A
stays fenced until rebuilt as a replica, and failback needs a reviewed switchover.
If gates are still unresolved at 02:45, keep settlement paused and escalate. Safety
gates outrank the recovery time objective. Before go-live, drill 40% packet loss, a
surviving old leader, paused workers, and lost acknowledgements.
