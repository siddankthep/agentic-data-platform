select
    id as payout_id,
    destination as destination_id,
    balance_transaction as balance_transaction_id,
    status,
    type as payout_type,
    method as payout_method,
    currency,
    amount / 100.0 as amount,
    amount_reversed / 100.0 as amount_reversed,
    automatic as is_automatic,
    failure_code,
    failure_message,
    to_timestamp(created) as created_at,
    to_timestamp(arrival_date) as arrival_date,
    to_timestamp(updated) as updated_at
from {{ source('stripe', 'payouts') }}
