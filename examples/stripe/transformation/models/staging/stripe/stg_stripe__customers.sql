select
    id as customer_id,
    name as customer_name,
    email,
    phone,
    address ->> 'country' as country,
    currency,
    balance / 100.0 as account_balance,
    delinquent as is_delinquent,
    livemode,
    to_timestamp(created) as created_at,
    to_timestamp(updated) as updated_at
from {{ source('stripe', 'customers') }}
where coalesce(is_deleted, false) = false
