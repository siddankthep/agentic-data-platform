with subscriptions as (
    select * from {{ ref('stg_stripe__subscriptions') }}
),

mrr as (
    select * from {{ ref('int_stripe__subscription_mrr') }}
)

select
    s.subscription_id,
    s.customer_id,
    s.status,
    s.currency,
    s.cancel_at_period_end,
    s.created_at,
    s.started_at,
    s.current_period_started_at,
    s.current_period_ends_at,
    s.trial_started_at,
    s.trial_ends_at,
    s.canceled_at,
    s.ended_at,
    s.status in ('active', 'trialing') as is_active,
    s.status = 'trialing' as is_trialing,
    s.status = 'canceled' as is_canceled,
    coalesce(m.item_count, 0) as item_count,
    coalesce(m.recurring_amount, 0) as recurring_amount,
    coalesce(m.mrr, 0) as mrr
from subscriptions s
left join mrr m on s.subscription_id = m.subscription_id
