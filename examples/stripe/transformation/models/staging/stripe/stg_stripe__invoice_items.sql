select
    id as invoice_item_id,
    customer as customer_id,
    invoice as invoice_id,
    subscription as subscription_id,
    subscription_item as subscription_item_id,
    description,
    amount / 100.0 as amount,
    currency,
    quantity,
    proration as is_proration,
    discountable,
    price ->> 'id' as price_id,
    to_timestamp(date) as item_date,
    to_timestamp(updated) as updated_at
from {{ source('stripe', 'invoice_items') }}
where coalesce(is_deleted, false) = false
