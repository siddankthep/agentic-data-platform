select
    li.invoice_line_item_id,
    li.invoice_id,
    i.customer_id,
    coalesce(li.subscription_id, i.subscription_id) as subscription_id,
    li.description,
    li.amount,
    li.currency,
    li.quantity,
    li.is_proration,
    li.price_id,
    li.period_started_at,
    li.period_ended_at,
    li.invoice_created_at
from {{ ref('stg_stripe__invoice_line_items') }} li
left join {{ ref('stg_stripe__invoices') }} i on li.invoice_id = i.invoice_id
