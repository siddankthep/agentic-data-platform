select
    id as subscription_item_id,
    subscription as subscription_id,
    customer as customer_id,
    price ->> 'id' as price_id,
    quantity,
    to_timestamp(start) as started_at,
    to_timestamp(ended_at) as ended_at,
    to_timestamp(created) as created_at,
    to_timestamp(subscription_updated) as updated_at
from {{ source('stripe', 'subscription_items') }}
