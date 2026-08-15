-- Stripe's own audit trail. Staged for lineage/debugging queries (e.g. "what
-- happened to object X"); no mart is built on top of it today.
select
    id as event_id,
    type as event_type,
    data -> 'object' ->> 'id' as object_id,
    api_version,
    livemode,
    pending_webhooks,
    to_timestamp(created) as created_at
from {{ source('stripe', 'events') }}
