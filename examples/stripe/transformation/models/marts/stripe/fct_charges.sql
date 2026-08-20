with charges as (
    select * from {{ ref('stg_stripe__charges') }}
),

balance_transactions as (
    select * from {{ ref('stg_stripe__balance_transactions') }}
)

select
    c.charge_id,
    c.customer_id,
    c.invoice_id,
    c.payment_intent_id,
    c.status,
    c.currency,
    c.amount,
    c.amount_captured,
    c.amount_refunded,
    c.is_paid,
    c.is_captured,
    c.is_refunded,
    c.is_disputed,
    c.failure_code,
    c.failure_message,
    c.card_brand,
    c.card_last4,
    bt.fee as processing_fee,
    bt.net as net_amount,
    c.created_at
from charges c
left join balance_transactions bt on c.balance_transaction_id = bt.balance_transaction_id
