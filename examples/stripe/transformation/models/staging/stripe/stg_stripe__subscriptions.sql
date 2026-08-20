select
    id as subscription_id,
    customer as customer_id,
    latest_invoice as latest_invoice_id,
    status,
    currency,
    quantity,
    cancel_at_period_end,
    to_timestamp(created) as created_at,
    to_timestamp(start_date) as started_at,
    to_timestamp(current_period_start) as current_period_started_at,
    to_timestamp(current_period_end) as current_period_ends_at,
    to_timestamp(canceled_at) as canceled_at,
    to_timestamp(ended_at) as ended_at,
    to_timestamp(trial_start) as trial_started_at,
    to_timestamp(trial_end) as trial_ends_at,
    to_timestamp(updated) as updated_at
from {{ source('stripe', 'subscriptions') }}
where coalesce(is_deleted, false) = false
