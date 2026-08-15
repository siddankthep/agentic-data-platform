-- One row per redeemable promotion: a shareable promotion code where one
-- exists, otherwise the coupon itself (coupons can be applied directly
-- without a code). is_deleted coupons are excluded upstream in staging.
with coupons as (
    select * from {{ ref('stg_stripe__coupons') }}
),

promotion_codes as (
    select * from {{ ref('stg_stripe__promotion_codes') }}
)

select
    pc.promotion_code_id,
    pc.code,
    c.coupon_id,
    c.coupon_name,
    c.percent_off,
    c.amount_off,
    c.currency,
    c.duration,
    c.duration_in_months,
    pc.is_active,
    coalesce(pc.times_redeemed, c.times_redeemed) as times_redeemed,
    coalesce(pc.max_redemptions, c.max_redemptions) as max_redemptions,
    pc.created_at,
    pc.expires_at
from promotion_codes pc
left join coupons c on pc.coupon_id = c.coupon_id

union all

select
    null as promotion_code_id,
    null as code,
    c.coupon_id,
    c.coupon_name,
    c.percent_off,
    c.amount_off,
    c.currency,
    c.duration,
    c.duration_in_months,
    c.is_valid as is_active,
    c.times_redeemed,
    c.max_redemptions,
    c.created_at,
    c.redeem_by as expires_at
from coupons c
where not exists (
    select 1 from promotion_codes pc where pc.coupon_id = c.coupon_id
)
