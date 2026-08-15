select
    id as price_id,
    product as product_id,
    active as is_active,
    currency,
    unit_amount / 100.0 as unit_amount,
    type as price_type,
    recurring ->> 'interval' as billing_interval,
    coalesce((recurring ->> 'interval_count')::int, 1) as billing_interval_count,
    nickname as price_nickname,
    to_timestamp(created) as created_at,
    to_timestamp(updated) as updated_at
from {{ source('stripe', 'prices') }}
where coalesce(is_deleted, false) = false
