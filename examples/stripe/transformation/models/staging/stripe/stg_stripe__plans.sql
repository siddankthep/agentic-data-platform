-- Stripe's legacy pricing object, superseded by `prices`. Kept staged for
-- completeness; `int_stripe__subscription_items_priced` joins through
-- `prices`, which every subscription_item in this dataset resolves against.
select
    id as plan_id,
    product as product_id,
    active as is_active,
    currency,
    amount / 100.0 as amount,
    interval as billing_interval,
    interval_count as billing_interval_count,
    nickname as plan_nickname,
    usage_type,
    to_timestamp(created) as created_at,
    to_timestamp(updated) as updated_at
from {{ source('stripe', 'plans') }}
where coalesce(is_deleted, false) = false
