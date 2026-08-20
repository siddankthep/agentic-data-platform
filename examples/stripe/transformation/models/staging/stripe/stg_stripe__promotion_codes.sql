select
    id as promotion_code_id,
    code,
    customer as customer_id,
    coupon ->> 'id' as coupon_id,
    active as is_active,
    times_redeemed,
    max_redemptions,
    to_timestamp(created) as created_at,
    to_timestamp(expires_at) as expires_at,
    to_timestamp(updated) as updated_at
from {{ source('stripe', 'promotion_codes') }}
