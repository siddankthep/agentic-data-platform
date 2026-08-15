select
    invoice_id,
    customer_id,
    subscription_id,
    invoice_number,
    status,
    currency,
    amount_due,
    amount_paid,
    amount_remaining,
    subtotal,
    total,
    tax,
    is_paid,
    is_attempted,
    attempt_count,
    billing_reason,
    collection_method,
    created_at,
    due_at,
    period_started_at,
    period_ended_at,
    amount_due > 0
    and not is_paid
    and (due_at is null or due_at < now()) as is_overdue
from {{ ref('stg_stripe__invoices') }}
