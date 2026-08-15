select
    id as payment_intent_id,
    customer as customer_id,
    invoice as invoice_id,
    latest_charge as latest_charge_id,
    payment_method as payment_method_id,
    status,
    currency,
    amount / 100.0 as amount,
    amount_received / 100.0 as amount_received,
    amount_capturable / 100.0 as amount_capturable,
    capture_method,
    confirmation_method,
    cancellation_reason,
    to_timestamp(created) as created_at,
    to_timestamp(canceled_at) as canceled_at,
    to_timestamp(updated) as updated_at
from {{ source('stripe', 'payment_intents') }}
