-- Seeds the Olist tables from db/seed/*.csv.
-- Run via `make seed`, which executes this inside the postgres container where
-- db/ is bind-mounted read-only at /db (server-side COPY resolves paths there).
-- Idempotent: truncates first, so it can be re-run without duplicating rows.
-- Load order respects the foreign keys declared in migration 000001.

BEGIN;

TRUNCATE
    order_reviews,
    order_payments,
    order_items,
    orders,
    products,
    product_category_name_translation,
    geolocation,
    sellers,
    customers;

COPY customers (
    customer_id, customer_unique_id, customer_zip_code_prefix,
    customer_city, customer_state
) FROM '/db/seed/olist_customers_dataset.csv'
  WITH (FORMAT csv, HEADER true);

COPY sellers (
    seller_id, seller_zip_code_prefix, seller_city, seller_state
) FROM '/db/seed/olist_sellers_dataset.csv'
  WITH (FORMAT csv, HEADER true);

COPY geolocation (
    geolocation_zip_code_prefix, geolocation_lat, geolocation_lng,
    geolocation_city, geolocation_state
) FROM '/db/seed/olist_geolocation_dataset.csv'
  WITH (FORMAT csv, HEADER true);

COPY product_category_name_translation (
    product_category_name, product_category_name_english
) FROM '/db/seed/product_category_name_translation.csv'
  WITH (FORMAT csv, HEADER true);

COPY products (
    product_id, product_category_name, product_name_lenght,
    product_description_lenght, product_photos_qty, product_weight_g,
    product_length_cm, product_height_cm, product_width_cm
) FROM '/db/seed/olist_products_dataset.csv'
  WITH (FORMAT csv, HEADER true, FORCE_NULL (product_category_name));

COPY orders (
    order_id, customer_id, order_status, order_purchase_timestamp,
    order_approved_at, order_delivered_carrier_date,
    order_delivered_customer_date, order_estimated_delivery_date
) FROM '/db/seed/olist_orders_dataset.csv'
  WITH (FORMAT csv, HEADER true);

COPY order_items (
    order_id, order_item_id, product_id, seller_id,
    shipping_limit_date, price, freight_value
) FROM '/db/seed/olist_order_items_dataset.csv'
  WITH (FORMAT csv, HEADER true);

COPY order_payments (
    order_id, payment_sequential, payment_type,
    payment_installments, payment_value
) FROM '/db/seed/olist_order_payments_dataset.csv'
  WITH (FORMAT csv, HEADER true);

COPY order_reviews (
    review_id, order_id, review_score, review_comment_title,
    review_comment_message, review_creation_date, review_answer_timestamp
) FROM '/db/seed/olist_order_reviews_dataset.csv'
  WITH (FORMAT csv, HEADER true,
        FORCE_NULL (review_comment_title, review_comment_message));

COMMIT;

ANALYZE;
