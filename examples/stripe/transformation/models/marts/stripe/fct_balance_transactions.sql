select
    balance_transaction_id,
    source_id,
    transaction_type,
    reporting_category,
    status,
    currency,
    amount,
    fee,
    net,
    description,
    created_at,
    available_on
from {{ ref('stg_stripe__balance_transactions') }}
