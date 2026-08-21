-- A tiny demo "source" so the Phase 1 walkthrough runs end to end without an
-- external system: two related tables with a PK/FK, mixed types, and an email
-- column the auto-classifier tags as PII.Sensitive.
--
-- Load with `make om-demo`, then `make om-ingest` catalogs + profiles it under
-- the `demo_warehouse` service (OM_SOURCE_SERVICE / OM_SCHEMA_INCLUDE=^demo$).
-- This is illustrative scaffolding, not part of any real pipeline.
CREATE SCHEMA IF NOT EXISTS demo;
DROP TABLE IF EXISTS demo.orders, demo.customers CASCADE;

CREATE TABLE demo.customers (
  customer_id int PRIMARY KEY,
  email       text,
  full_name   text,
  country     text,
  created_at  timestamp
);

CREATE TABLE demo.orders (
  order_id     int PRIMARY KEY,
  customer_id  int REFERENCES demo.customers(customer_id),
  amount_cents int,
  status       text,
  ordered_at   timestamp
);

INSERT INTO demo.customers
SELECT g, 'user' || g || '@example.com', 'Customer ' || g,
       (ARRAY['US','GB','DE','FR','IN'])[1 + (g % 5)],
       now() - (g || ' days')::interval
FROM generate_series(1, 200) g;

INSERT INTO demo.orders
SELECT g, 1 + (g % 200), (100 + (g * 7) % 9000),
       (ARRAY['paid','refunded','pending'])[1 + (g % 3)],
       now() - (g || ' hours')::interval
FROM generate_series(1, 1000) g;
