select
    id as checkout_session_id,
    customer as customer_id,
    subscription as subscription_id,
    payment_intent as payment_intent_id,
    status,
    payment_status,
    mode as checkout_mode,
    currency,
    amount_total / 100.0 as amount_total,
    amount_subtotal / 100.0 as amount_subtotal,
    customer_email,
    to_timestamp(created) as created_at,
    to_timestamp(expires_at) as expires_at,
    to_timestamp(updated) as updated_at
from {{ source('stripe', 'checkout_sessions') }}
