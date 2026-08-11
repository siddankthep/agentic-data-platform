-- Olist Brazilian e-commerce dataset schema.
--
-- Lives in `source`, not `public`: this models the operational database an EL
-- tool reads *from*. Keeping it in its own schema makes the boundary explicit
-- once Airbyte lands its output in `raw` and dbt builds `staging`/`marts` —
-- every schema then has exactly one owner, and nothing piles up in `public`.
--
-- Column names mirror the source CSV headers verbatim (including the
-- upstream "lenght" typo in products) so the CSV -> table mapping is 1:1.
CREATE SCHEMA IF NOT EXISTS source;

CREATE TABLE source.customers (
    customer_id text PRIMARY KEY,
    customer_unique_id text NOT NULL,
    customer_zip_code_prefix text NOT NULL,
    customer_city text,
    customer_state text
);
CREATE TABLE source.sellers (
    seller_id text PRIMARY KEY,
    seller_zip_code_prefix text NOT NULL,
    seller_city text,
    seller_state text
);
-- Zip prefixes repeat across many lat/lng points, so there is no natural key.
CREATE TABLE source.geolocation (
    geolocation_zip_code_prefix text NOT NULL,
    geolocation_lat double precision,
    geolocation_lng double precision,
    geolocation_city text,
    geolocation_state text
);
CREATE TABLE source.product_category_name_translation (
    product_category_name text PRIMARY KEY,
    product_category_name_english text NOT NULL
);
CREATE TABLE source.products (
    product_id text PRIMARY KEY,
    product_category_name text,
    product_name_lenght integer,
    product_description_lenght integer,
    product_photos_qty integer,
    product_weight_g integer,
    product_length_cm integer,
    product_height_cm integer,
    product_width_cm integer
);
CREATE TABLE source.orders (
    order_id text PRIMARY KEY,
    customer_id text NOT NULL REFERENCES source.customers (customer_id),
    order_status text NOT NULL,
    order_purchase_timestamp timestamp,
    order_approved_at timestamp,
    order_delivered_carrier_date timestamp,
    order_delivered_customer_date timestamp,
    order_estimated_delivery_date timestamp
);
CREATE TABLE source.order_items (
    order_id text NOT NULL REFERENCES source.orders (order_id),
    order_item_id integer NOT NULL,
    product_id text NOT NULL REFERENCES source.products (product_id),
    seller_id text NOT NULL REFERENCES source.sellers (seller_id),
    shipping_limit_date timestamp,
    price numeric(12, 2),
    freight_value numeric(12, 2),
    PRIMARY KEY (order_id, order_item_id)
);
CREATE TABLE source.order_payments (
    order_id text NOT NULL REFERENCES source.orders (order_id),
    payment_sequential integer NOT NULL,
    payment_type text,
    payment_installments integer,
    payment_value numeric(12, 2),
    PRIMARY KEY (order_id, payment_sequential)
);
-- review_id is not unique upstream (the same review can appear against more
-- than one order), so this table intentionally has no primary key.
CREATE TABLE source.order_reviews (
    review_id text NOT NULL,
    order_id text NOT NULL REFERENCES source.orders (order_id),
    review_score integer,
    review_comment_title text,
    review_comment_message text,
    review_creation_date timestamp,
    review_answer_timestamp timestamp
);
CREATE INDEX ON source.orders (customer_id);
CREATE INDEX ON source.orders (order_status);
CREATE INDEX ON source.orders (order_purchase_timestamp);
CREATE INDEX ON source.order_items (product_id);
CREATE INDEX ON source.order_items (seller_id);
CREATE INDEX ON source.order_reviews (review_id);
CREATE INDEX ON source.order_reviews (order_id);
CREATE INDEX ON source.products (product_category_name);
CREATE INDEX ON source.geolocation (geolocation_zip_code_prefix);
