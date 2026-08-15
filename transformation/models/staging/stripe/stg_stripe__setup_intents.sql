select
    id as setup_intent_id,
    customer as customer_id,
    payment_method as payment_method_id,
    status,
    usage,
    cancellation_reason,
    to_timestamp(created) as created_at,
    to_timestamp(updated) as updated_at
from {{ source('stripe', 'setup_intents') }}
