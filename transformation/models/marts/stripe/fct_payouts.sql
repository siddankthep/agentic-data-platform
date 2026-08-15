select
    payout_id,
    destination_id,
    status,
    payout_type,
    payout_method,
    currency,
    amount,
    amount_reversed,
    is_automatic,
    failure_code,
    failure_message,
    created_at,
    arrival_date
from {{ ref('stg_stripe__payouts') }}
