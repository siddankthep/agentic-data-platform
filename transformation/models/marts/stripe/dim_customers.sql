with customers as (
    select * from {{ ref('stg_stripe__customers') }}
),

invoices as (
    select * from {{ ref('stg_stripe__invoices') }}
),

charges as (
    select * from {{ ref('stg_stripe__charges') }}
),

subscriptions as (
    select * from {{ ref('stg_stripe__subscriptions') }}
),

invoice_agg as (
    select
        customer_id,
        count(*) filter (where is_paid) as paid_invoice_count,
        sum(amount_paid) filter (where is_paid) as lifetime_billed
    from invoices
    group by 1
),

charge_agg as (
    select
        customer_id,
        count(*) filter (where status = 'succeeded') as successful_charge_count,
        sum(amount_captured) filter (where status = 'succeeded') as lifetime_value,
        sum(amount_refunded) as lifetime_refunded
    from charges
    group by 1
),

subscription_agg as (
    select
        customer_id,
        count(*) as subscription_count,
        count(*) filter (where status in ('active', 'trialing')) as active_subscription_count,
        min(started_at) as first_subscription_started_at
    from subscriptions
    group by 1
)

select
    c.customer_id,
    c.customer_name,
    c.email,
    c.country,
    c.currency,
    c.account_balance,
    c.is_delinquent,
    c.created_at,
    coalesce(sa.subscription_count, 0) as subscription_count,
    coalesce(sa.active_subscription_count, 0) as active_subscription_count,
    coalesce(sa.active_subscription_count, 0) > 0 as is_active_subscriber,
    sa.first_subscription_started_at,
    coalesce(ia.paid_invoice_count, 0) as paid_invoice_count,
    coalesce(ia.lifetime_billed, 0) as lifetime_billed,
    coalesce(ca.successful_charge_count, 0) as successful_charge_count,
    coalesce(ca.lifetime_value, 0) as lifetime_value,
    coalesce(ca.lifetime_refunded, 0) as lifetime_refunded
from customers c
left join invoice_agg ia on c.customer_id = ia.customer_id
left join charge_agg ca on c.customer_id = ca.customer_id
left join subscription_agg sa on c.customer_id = sa.customer_id
