select
    id as credit_note_id,
    customer as customer_id,
    invoice as invoice_id,
    number as credit_note_number,
    status,
    type as credit_note_type,
    reason,
    currency,
    amount / 100.0 as amount,
    total / 100.0 as total,
    subtotal / 100.0 as subtotal,
    to_timestamp(created) as created_at,
    to_timestamp(voided_at) as voided_at,
    to_timestamp(effective_at) as effective_at,
    to_timestamp(updated) as updated_at
from {{ source('stripe', 'credit_notes') }}
