select
    id as dispute_id,
    charge as charge_id,
    payment_intent as payment_intent_id,
    balance_transaction as balance_transaction_id,
    status,
    reason,
    currency,
    amount / 100.0 as amount,
    is_charge_refundable,
    to_timestamp(created) as created_at,
    to_timestamp(updated) as updated_at
from {{ source('stripe', 'disputes') }}
