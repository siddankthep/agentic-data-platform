select
    d.dispute_id,
    d.charge_id,
    c.customer_id,
    d.status,
    d.reason,
    d.currency,
    d.amount,
    d.is_charge_refundable,
    d.created_at
from {{ ref('stg_stripe__disputes') }} d
left join {{ ref('stg_stripe__charges') }} c on d.charge_id = c.charge_id
