-- One row per subscription line item, priced and normalized to a monthly
-- recurring amount regardless of the underlying billing interval. This is
-- the one place "MRR" gets defined -- fct_subscriptions sums it up per
-- subscription. Weekly/daily intervals are normalized using average
-- days-per-month (30.44) and days-per-week (7), not a fixed "4 weeks".
with subscription_items as (
    select * from {{ ref('stg_stripe__subscription_items') }}
),

prices as (
    select * from {{ ref('stg_stripe__prices') }}
)

select
    si.subscription_item_id,
    si.subscription_id,
    si.customer_id,
    si.price_id,
    si.quantity,
    si.started_at,
    si.ended_at,
    p.product_id,
    p.currency,
    p.unit_amount,
    p.billing_interval,
    p.billing_interval_count,
    p.unit_amount * si.quantity as recurring_amount,
    round(
        case p.billing_interval
            when 'day' then p.unit_amount * si.quantity * 30.44 / nullif(p.billing_interval_count, 0)
            when 'week' then p.unit_amount * si.quantity * (30.44 / 7) / nullif(p.billing_interval_count, 0)
            when 'month' then p.unit_amount * si.quantity / nullif(p.billing_interval_count, 0)
            when 'year' then p.unit_amount * si.quantity / (12 * nullif(p.billing_interval_count, 0))
        end,
        2
    ) as mrr_amount
from subscription_items si
left join prices p on si.price_id = p.price_id
