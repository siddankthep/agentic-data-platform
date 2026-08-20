select
    id as coupon_id,
    name as coupon_name,
    duration,
    duration_in_months,
    amount_off / 100.0 as amount_off,
    percent_off,
    currency,
    valid as is_valid,
    times_redeemed,
    max_redemptions,
    to_timestamp(created) as created_at,
    to_timestamp(nullif(redeem_by, '')::double precision) as redeem_by
from {{ source('stripe', 'coupons') }}
where coalesce(is_deleted, false) = false
