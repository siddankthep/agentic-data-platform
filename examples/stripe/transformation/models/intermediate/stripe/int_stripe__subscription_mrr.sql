-- Rolls subscription items up to one row per subscription. Reflects the
-- subscription's *current* item configuration -- there is no plan-change
-- history in this dataset, so this is a snapshot, not a time series.
select
    subscription_id,
    customer_id,
    count(*) as item_count,
    max(currency) as currency,
    sum(recurring_amount) as recurring_amount,
    sum(mrr_amount) as mrr
from {{ ref('int_stripe__subscription_items_priced') }}
group by 1, 2
