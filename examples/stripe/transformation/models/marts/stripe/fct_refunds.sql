select
    r.refund_id,
    r.charge_id,
    c.customer_id,
    r.payment_intent_id,
    r.status,
    r.reason,
    r.currency,
    r.amount,
    r.created_at
from {{ ref('stg_stripe__refunds') }} r
left join {{ ref('stg_stripe__charges') }} c on r.charge_id = c.charge_id
