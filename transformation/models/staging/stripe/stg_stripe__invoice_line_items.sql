-- In this Stripe test account `type`, `price`, `plan`, `subscription` and
-- `subscription_item` on the line item itself come back empty even for
-- subscription invoices — the connector doesn't backfill them from the
-- parent invoice. `description` is the only reliable label for what a line
-- represents. Don't rely on this stream for product-level revenue splits;
-- use `int_stripe__subscription_items_priced` (via `prices`) for that
-- instead, and treat this stream as invoice-level billing detail only.
select
    id as invoice_line_item_id,
    coalesce(invoice_id, invoice) as invoice_id,
    description,
    amount / 100.0 as amount,
    currency,
    quantity,
    proration as is_proration,
    nullif(price ->> 'id', '') as price_id,
    nullif(subscription, '') as subscription_id,
    to_timestamp((period ->> 'start')::bigint) as period_started_at,
    to_timestamp((period ->> 'end')::bigint) as period_ended_at,
    to_timestamp(invoice_created) as invoice_created_at
from {{ source('stripe', 'invoice_line_items') }}
