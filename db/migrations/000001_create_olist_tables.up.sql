-- Olist Brazilian e-commerce dataset schema.
-- Column names mirror the source CSV headers verbatim (including the
-- upstream "lenght" typo in products) so the CSV -> table mapping is 1:1.
CREATE TABLE customers (
    customer_id text PRIMARY KEY,
    customer_unique_id text NOT NULL,
    customer_zip_code_prefix text NOT NULL,
    customer_city text,
    customer_state text
);
CREATE TABLE sellers (
    seller_id text PRIMARY KEY,
    seller_zip_code_prefix text NOT NULL,
    seller_city text,
    seller_state text
);
-- Zip prefixes repeat across many lat/lng points, so there is no natural key.
CREATE TABLE geolocation (
    geolocation_zip_code_prefix text NOT NULL,
    geolocation_lat double precision,
    geolocation_lng double precision,
    geolocation_city text,
    geolocation_state text
);
CREATE TABLE product_category_name_translation (
    product_category_name text PRIMARY KEY,
    product_category_name_english text NOT NULL
);
CREATE TABLE products (
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
CREATE TABLE orders (
    order_id text PRIMARY KEY,
    customer_id text NOT NULL REFERENCES customers (customer_id),
    order_status text NOT NULL,
    order_purchase_timestamp timestamp,
    order_approved_at timestamp,
    order_delivered_carrier_date timestamp,
    order_delivered_customer_date timestamp,
    order_estimated_delivery_date timestamp
);
CREATE TABLE order_items (
    order_id text NOT NULL REFERENCES orders (order_id),
    order_item_id integer NOT NULL,
    product_id text NOT NULL REFERENCES products (product_id),
    seller_id text NOT NULL REFERENCES sellers (seller_id),
    shipping_limit_date timestamp,
    price numeric(12, 2),
    freight_value numeric(12, 2),
    PRIMARY KEY (order_id, order_item_id)
);
CREATE TABLE order_payments (
    order_id text NOT NULL REFERENCES orders (order_id),
    payment_sequential integer NOT NULL,
    payment_type text,
    payment_installments integer,
    payment_value numeric(12, 2),
    PRIMARY KEY (order_id, payment_sequential)
);
-- review_id is not unique upstream (the same review can appear against more
-- than one order), so this table intentionally has no primary key.
CREATE TABLE order_reviews (
    review_id text NOT NULL,
    order_id text NOT NULL REFERENCES orders (order_id),
    review_score integer,
    review_comment_title text,
    review_comment_message text,
    review_creation_date timestamp,
    review_answer_timestamp timestamp
);
CREATE INDEX ON orders (customer_id);
CREATE INDEX ON orders (order_status);
CREATE INDEX ON orders (order_purchase_timestamp);
CREATE INDEX ON order_items (product_id);
CREATE INDEX ON order_items (seller_id);
CREATE INDEX ON order_reviews (review_id);
CREATE INDEX ON order_reviews (order_id);
CREATE INDEX ON products (product_category_name);
CREATE INDEX ON geolocation (geolocation_zip_code_prefix);