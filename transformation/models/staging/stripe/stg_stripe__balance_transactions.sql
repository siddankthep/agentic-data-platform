select
    id as balance_transaction_id,
    source as source_id,
    type as transaction_type,
    reporting_category,
    status,
    currency,
    amount / 100.0 as amount,
    fee / 100.0 as fee,
    net / 100.0 as net,
    description,
    to_timestamp(created) as created_at,
    to_timestamp(available_on) as available_on
from {{ source('stripe', 'balance_transactions') }}
