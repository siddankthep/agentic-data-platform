select
    id as product_id,
    name as product_name,
    description as product_description,
    type as product_type,
    active as is_active,
    default_price as default_price_id,
    to_timestamp(created) as created_at,
    to_timestamp(updated) as updated_at
from {{ source('stripe', 'products') }}
where coalesce(is_deleted, false) = false
