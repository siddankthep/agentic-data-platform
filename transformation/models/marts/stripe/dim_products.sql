with products as (
    select * from {{ ref('stg_stripe__products') }}
),

prices as (
    select * from {{ ref('stg_stripe__prices') }}
)

select
    p.product_id,
    p.product_name,
    p.product_description,
    p.is_active as product_is_active,
    p.created_at,
    pr.price_id as default_price_id,
    pr.currency,
    pr.unit_amount as price_amount,
    pr.billing_interval,
    pr.billing_interval_count,
    round(
        case pr.billing_interval
            when 'day' then pr.unit_amount * 30.44 / nullif(pr.billing_interval_count, 0)
            when 'week' then pr.unit_amount * (30.44 / 7) / nullif(pr.billing_interval_count, 0)
            when 'month' then pr.unit_amount / nullif(pr.billing_interval_count, 0)
            when 'year' then pr.unit_amount / (12 * nullif(pr.billing_interval_count, 0))
        end,
        2
    ) as monthly_price
from products p
left join prices pr on p.default_price_id = pr.price_id
