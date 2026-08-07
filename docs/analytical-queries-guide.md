# Modelling complex analytical questions in Cube (Olist)

A guide to implementing the hard questions against the Olist dataset — the ones
that can't be answered by adding another `type: sum` measure.

Each section states the question, the modelling change it requires, the YAML, the
query, and the pitfall that makes it wrong if you skip a step.

---

## Contents

- [Foundations](#foundations) — fix these before anything else
- [Group 1: Fan-out and multi-fact queries](#group-1-fan-out-and-multi-fact-queries)
- [Group 2: Entity resolution and cohorts](#group-2-entity-resolution-and-cohorts)
- [Group 3: Date arithmetic between columns](#group-3-date-arithmetic-between-columns)
- [Group 4: Ranking and windowing](#group-4-ranking-and-windowing)
- [Group 5: Cross-table geography](#group-5-cross-table-geography)
- [Group 6: Conditional aggregation](#group-6-conditional-aggregation)
- [Best practices summary](#best-practices-summary)

---

## Foundations

Four model-wide problems block most of what follows. Fix them first.

### F1. Qualify every column with `{CUBE}`

Cube pastes `sql:` into the generated query verbatim. A bare column name resolves
fine in a single-cube query and becomes `column reference "order_id" is ambiguous`
the moment a join brings a second table into scope.

```yaml
# Wrong — breaks in joined queries
- name: customer_id
  sql: customer_id
  type: string

# Right
- name: customer_id
  sql: "{CUBE}.customer_id"
  type: string
```

Apply it to measures too (`sql: "{CUBE}.price"`). Do it everywhere, not just on
columns that currently collide — a future join can introduce a collision into a
cube you never touched.

### F2. Joins are directional

A join declared inside `order_items` pointing at `orders` creates the path
`order_items → orders`. It does **not** create `orders → order_items`. Views and
multi-fact queries traverse outward from a root cube, so the hub cube needs the
reverse declarations.

Add to `orders`:

```yaml
joins:
  - name: customers
    sql: "{CUBE}.customer_id = {customers}.customer_id"
    relationship: many_to_one

  - name: order_items
    sql: "{CUBE}.order_id = {order_items}.order_id"
    relationship: one_to_many

  - name: order_payments
    sql: "{CUBE}.order_id = {order_payments}.order_id"
    relationship: one_to_many

  - name: order_reviews
    sql: "{CUBE}.order_id = {order_reviews}.order_id"
    relationship: one_to_many
```

`relationship` is not cosmetic — it is what tells Cube's aggregation planner
whether a join can inflate a measure, and it drives the multi-fact rewrite in
[Q1](#q1-item-revenue-vs-payment-value-per-month).

### F3. `order_reviews` has a broken primary key

The migration says so explicitly: `review_id` is not unique upstream, the same
review can appear against more than one order, and the table has no primary key.
Declaring `review_id` as `primary_key` tells Cube something false, and
`count_distinct` on it will under-count.

Redefine the cube over a deduplicating query so it has a real grain of one row
per order:

```yaml
cubes:
  - name: order_reviews
    data_source: default
    sql: >
      SELECT DISTINCT ON (order_id)
        order_id,
        review_id,
        review_score,
        review_comment_title,
        review_creation_date,
        review_answer_timestamp
      FROM public.order_reviews
      ORDER BY order_id, review_answer_timestamp DESC

    dimensions:
      - name: order_id
        sql: "{CUBE}.order_id"
        type: string
        primary_key: true

      - name: review_score
        sql: "{CUBE}.review_score"
        type: number
```

`DISTINCT ON` keeps the most recently answered review per order. If you'd rather
keep every review, keep the raw table but build the primary key explicitly as
`sql: "{CUBE}.review_id || '-' || {CUBE}.order_id"` — just be aware that the cube
is then *not* at order grain and every join through `orders` fans out.

### F4. Expose the dimensions the questions need

Several columns exist in Postgres but only appear inside measures, or not at all.
Nothing downstream works without them:

| Cube | Add as dimension |
|---|---|
| `customers` | `customer_unique_id`, `customer_zip_code_prefix` |
| `sellers` | `seller_zip_code_prefix` |
| `order_items` | `price`, `freight_value` |
| `order_payments` | `payment_installments`, `payment_value` |
| `order_reviews` | `review_score` |
| `products` | `product_photos_qty`, `product_weight_g` |

A column can be both a dimension and the basis of a measure. That's normal and
correct — you need `price` as a dimension to bucket by it and as a measure to sum
it.

---

## Group 1: Fan-out and multi-fact queries

This is the category that returns *plausible wrong numbers* instead of erroring.
It deserves the most care.

### Q1. Item revenue vs. payment value per month

> For each month, what's the gap between order item revenue and what customers
> actually paid?

**Why it's hard.** `order_items` and `order_payments` are separate fact tables
that both join to `orders`. A naive join produces a cartesian product per order:
a 3-item order paid in 2 instalments yields 6 rows. `total_price` inflates 2×,
`total_payment_value` inflates 3×. Neither number is flagged as wrong.

**Implementation.** Do *not* write a query that touches both cubes directly.
Build a view rooted at the shared cube, and let Cube's multi-fact join generate
two independently-aggregated subqueries that are then full-outer-joined on the
common dimensions.

```yaml
# model/views/order_economics.yml
views:
  - name: order_economics
    description: >
      Order-grain economics. Item revenue and payment value are aggregated
      independently and joined on order dimensions — safe to combine.

    cubes:
      - join_path: orders
        includes:
          - order_purchase_timestamp
          - order_status
          - count

      - join_path: orders.order_items
        prefix: true
        includes:
          - total_price
          - total_freight_value

      - join_path: orders.order_payments
        prefix: true
        includes:
          - total_payment_value
```

This requires the `one_to_many` joins from [F2](#f2-joins-are-directional).

**Query.**

```json
{
  "measures": [
    "order_economics.order_items_total_price",
    "order_economics.order_payments_total_payment_value"
  ],
  "timeDimensions": [{
    "dimension": "order_economics.order_purchase_timestamp",
    "granularity": "month"
  }]
}
```

**Verify it worked.** Inspect the generated SQL — you should see two `GROUP BY`
subqueries combined with a `FULL OUTER JOIN`, not one flat join:

```bash
curl -s -G 'http://localhost:4000/cubejs-api/v1/sql' \
  --data-urlencode 'query={"measures":["order_economics.order_items_total_price","order_economics.order_payments_total_payment_value"],"timeDimensions":[{"dimension":"order_economics.order_purchase_timestamp","granularity":"month"}]}' \
  | jq -r '.sql.sql[0]'
```

If you see a single `FROM orders JOIN order_items JOIN order_payments`, the
multi-fact rewrite did not engage — usually a missing `one_to_many` declaration.

> **Best practice.** Any time two fact cubes appear in one query, the answer is a
> view with explicit `join_path`s. Views are not just for hiding columns; they are
> how you pin a safe join path so consumers (and LLM agents) can't construct an
> inflated one.

### Q2. Freight as a share of payment value

> What share of an order's payment value is freight?

**Why it's hard.** Same fan-out as Q1, plus it's a ratio across two fact tables,
so it cannot be a `type: number` measure inside either cube — neither cube can see
the other's aggregate at its own grain.

**Implementation.** Compute both numerator and denominator through the
`order_economics` view, then divide. Two options:

*Option A — divide in the client.* Simplest and always correct. Request both
measures, divide the results.

*Option B — a dedicated order-grain cube.* If this ratio is a first-class metric
you want to filter and slice on, pre-flatten to one row per order:

```yaml
cubes:
  - name: order_economics_facts
    data_source: default
    sql: >
      SELECT
        o.order_id,
        o.order_purchase_timestamp,
        o.order_status,
        i.item_revenue,
        i.freight,
        p.paid
      FROM public.orders o
      LEFT JOIN (
        SELECT order_id,
               SUM(price)         AS item_revenue,
               SUM(freight_value) AS freight
        FROM public.order_items GROUP BY order_id
      ) i ON i.order_id = o.order_id
      LEFT JOIN (
        SELECT order_id, SUM(payment_value) AS paid
        FROM public.order_payments GROUP BY order_id
      ) p ON p.order_id = o.order_id

    dimensions:
      - name: order_id
        sql: "{CUBE}.order_id"
        type: string
        primary_key: true

    measures:
      - name: total_freight
        sql: "{CUBE}.freight"
        type: sum

      - name: total_paid
        sql: "{CUBE}.paid"
        type: sum

      - name: freight_share
        sql: "{CUBE.total_freight} / NULLIF({CUBE.total_paid}, 0)"
        type: number
        format: percent
```

**Best practice.** A ratio measure must reference other measures with
`{CUBE.measure_name}`, never raw columns — that makes it `SUM(a)/SUM(b)`
(correct) rather than `AVG(a/b)` (wrong, and differently wrong at every
granularity). Always wrap the denominator in `NULLIF(..., 0)`.

### Q3. Average review score by product category

> Average review score by product category.

**Why it's hard.** The path is
`order_reviews → orders → order_items → products`. One review attaches to one
order; an order with three items produces three rows; the review score is counted
three times. Categories that attract multi-item orders get systematically
over-weighted.

**Implementation.** Decide the grain first, because there are two legitimate and
different answers:

1. *"Average score of orders containing this category"* — each review counts once
   per order, regardless of item count.
2. *"Average score weighted by items sold"* — each review counts once per item.

For (1), the correct approach, build an order-to-category bridge that is distinct
on `(order_id, category)`:

```yaml
cubes:
  - name: order_category_reviews
    data_source: default
    sql: >
      SELECT DISTINCT
        oi.order_id,
        p.product_category_name,
        t.product_category_name_english,
        r.review_score
      FROM public.order_items oi
      JOIN public.products p
        ON p.product_id = oi.product_id
      LEFT JOIN public.product_category_name_translation t
        ON t.product_category_name = p.product_category_name
      JOIN (
        SELECT DISTINCT ON (order_id) order_id, review_score
        FROM public.order_reviews
        ORDER BY order_id, review_answer_timestamp DESC
      ) r ON r.order_id = oi.order_id

    dimensions:
      - name: id
        sql: "{CUBE}.order_id || '-' || COALESCE({CUBE}.product_category_name, 'unknown')"
        type: string
        primary_key: true

      - name: category
        sql: "COALESCE({CUBE}.product_category_name_english, {CUBE}.product_category_name)"
        type: string

    measures:
      - name: avg_review_score
        sql: "{CUBE}.review_score"
        type: avg

      - name: reviewed_orders
        sql: "{CUBE}.order_id"
        type: count_distinct
```

**Best practice.** When a metric's grain differs from any physical table's grain,
create a cube over a `sql:` query that *is* at that grain. Do not try to correct
fan-out with filters or `count_distinct` patches after the fact — those fix the
count and leave the average wrong.

---

## Group 2: Entity resolution and cohorts

### Q4. How many customers are repeat buyers?

**Why it's hard.** In Olist, `customer_id` is issued *per order* — it is not a
person. `customer_unique_id` is the person. Counting distinct `customer_id`
counts orders. And "repeat buyer" is a filter on an aggregate (`HAVING COUNT(*) >
1`), which is a second level of aggregation.

**Implementation.**

```yaml
cubes:
  - name: buyers
    data_source: default
    sql: >
      SELECT
        c.customer_unique_id,
        MIN(o.order_purchase_timestamp) AS first_order_at,
        MAX(o.order_purchase_timestamp) AS last_order_at,
        COUNT(DISTINCT o.order_id)      AS order_count
      FROM public.orders o
      JOIN public.customers c ON c.customer_id = o.customer_id
      GROUP BY c.customer_unique_id

    dimensions:
      - name: customer_unique_id
        sql: "{CUBE}.customer_unique_id"
        type: string
        primary_key: true

      - name: order_count
        sql: "{CUBE}.order_count"
        type: number

      - name: first_order_at
        sql: "{CUBE}.first_order_at"
        type: time

      - name: lifecycle
        type: string
        sql: >
          CASE WHEN {CUBE}.order_count = 1 THEN 'one-time'
               WHEN {CUBE}.order_count BETWEEN 2 AND 4 THEN 'repeat'
               ELSE 'loyal' END

    measures:
      - name: count
        type: count

      - name: repeat_buyers
        type: count
        filters:
          - sql: "{CUBE}.order_count > 1"

      - name: repeat_rate
        sql: "{CUBE.repeat_buyers} / NULLIF({CUBE.count}, 0)"
        type: number
        format: percent
```

**Best practice.** `filters:` on a measure compiles to
`COUNT(CASE WHEN ... END)` — one pass over the data, and it composes with any
dimension you group by. Reach for it before you consider two separate queries.

Note the `lifecycle` dimension: bucketing an aggregate into a *dimension* is only
possible because the cube's grain is already one row per buyer. This is the whole
reason to build the intermediate cube.

### Q5. 90-day second-order retention by cohort

> Of customers who first bought in Jan 2017, what fraction bought again within 90
> days?

**Why it's hard.** Every measurement is relative to a per-customer anchor date,
not a fixed calendar date. The cohort grouping and the conversion window come
from different rows of the same table.

**Implementation.** Extend the `buyers` pattern with the second-order timestamp:

```yaml
cubes:
  - name: buyer_cohorts
    data_source: default
    sql: >
      WITH ranked AS (
        SELECT
          c.customer_unique_id,
          o.order_id,
          o.order_purchase_timestamp,
          ROW_NUMBER() OVER (
            PARTITION BY c.customer_unique_id
            ORDER BY o.order_purchase_timestamp
          ) AS order_seq
        FROM public.orders o
        JOIN public.customers c ON c.customer_id = o.customer_id
      )
      SELECT
        customer_unique_id,
        MIN(order_purchase_timestamp) FILTER (WHERE order_seq = 1) AS first_order_at,
        MIN(order_purchase_timestamp) FILTER (WHERE order_seq = 2) AS second_order_at
      FROM ranked
      GROUP BY customer_unique_id

    dimensions:
      - name: customer_unique_id
        sql: "{CUBE}.customer_unique_id"
        type: string
        primary_key: true

      - name: cohort_month
        sql: "DATE_TRUNC('month', {CUBE}.first_order_at)"
        type: time

      - name: days_to_second_order
        type: number
        sql: >
          EXTRACT(EPOCH FROM ({CUBE}.second_order_at - {CUBE}.first_order_at)) / 86400

    measures:
      - name: cohort_size
        type: count

      - name: retained_90d
        type: count
        filters:
          - sql: >
              {CUBE}.second_order_at IS NOT NULL
              AND {CUBE}.second_order_at <= {CUBE}.first_order_at + INTERVAL '90 days'

      - name: retention_rate_90d
        sql: "{CUBE.retained_90d} / NULLIF({CUBE.cohort_size}, 0)"
        type: number
        format: percent
```

**Query.** Group by `cohort_month`, request `cohort_size` and
`retention_rate_90d`.

**Best practice.** Note `cohort_month` is a `type: time` dimension built from a
`DATE_TRUNC` — Cube will still let you apply granularity on top of it, so keep the
underlying column raw and truncate only where the semantics demand it. Don't
hardcode the 90-day window in three places; if you need several windows, define
`retained_30d` / `retained_90d` / `retained_365d` as sibling filtered measures.

### Q6. Most frequently co-purchased product pairs

**Why it's hard.** This is a self-join of `order_items` to itself on `order_id`.
There is no measure, dimension, or join that expresses it — the output grain
(product *pair*) doesn't exist as a row anywhere in the source.

**Implementation.** A dedicated cube. Note the `a.product_id < b.product_id`
predicate: without it every pair appears twice (A-B and B-A) and every product
pairs with itself.

```yaml
cubes:
  - name: product_affinity
    data_source: default
    sql: >
      SELECT
        a.product_id     AS product_a,
        b.product_id     AS product_b,
        pa.product_category_name AS category_a,
        pb.product_category_name AS category_b,
        COUNT(DISTINCT a.order_id) AS co_purchase_orders
      FROM public.order_items a
      JOIN public.order_items b
        ON a.order_id = b.order_id
       AND a.product_id < b.product_id
      JOIN public.products pa ON pa.product_id = a.product_id
      JOIN public.products pb ON pb.product_id = b.product_id
      GROUP BY 1, 2, 3, 4
      HAVING COUNT(DISTINCT a.order_id) >= 3

    dimensions:
      - name: pair_id
        sql: "{CUBE}.product_a || '|' || {CUBE}.product_b"
        type: string
        primary_key: true

      - name: category_pair
        sql: "{CUBE}.category_a || ' + ' || {CUBE}.category_b"
        type: string

    measures:
      - name: co_purchases
        sql: "{CUBE}.co_purchase_orders"
        type: sum

    pre_aggregations:
      - name: pairs_rollup
        measures:
          - co_purchases
        dimensions:
          - category_pair
```

**Best practice.** The `HAVING COUNT(...) >= 3` is load-bearing. A self-join over
~112k order items is O(items² per order); without a support threshold the result
set is enormous and mostly noise. Push the threshold into the cube SQL, not into
a query filter — a query filter runs *after* the expensive join.

This cube is also the clearest case for a **pre-aggregation**: the underlying
query is expensive and the result changes only when new orders land.

---

## Group 3: Date arithmetic between columns

All of these follow one pattern: a calculated dimension over two timestamp
columns, then measures on top of it. The pattern generalises; the details differ.

### Q7. Which sellers ship late most often?

> Compare `order_items.shipping_limit_date` to `orders.order_delivered_carrier_date`.

**Why it's hard.** The two columns live in different cubes, so the comparison
can't be a dimension in either one without depending on join context.

**Implementation.** Put the comparison in an item-grain cube that resolves the
join in SQL:

```yaml
cubes:
  - name: shipment_performance
    data_source: default
    sql: >
      SELECT
        oi.order_id,
        oi.order_item_id,
        oi.seller_id,
        oi.shipping_limit_date,
        o.order_delivered_carrier_date,
        o.order_purchase_timestamp,
        EXTRACT(EPOCH FROM (o.order_delivered_carrier_date - oi.shipping_limit_date))
          / 86400 AS days_late
      FROM public.order_items oi
      JOIN public.orders o ON o.order_id = oi.order_id

    joins:
      - name: sellers
        sql: "{CUBE}.seller_id = {sellers}.seller_id"
        relationship: many_to_one

    dimensions:
      - name: id
        sql: "{CUBE}.order_id || '-' || {CUBE}.order_item_id"
        type: string
        primary_key: true

      - name: days_late
        sql: "{CUBE}.days_late"
        type: number

    measures:
      - name: shipments
        type: count

      - name: late_shipments
        type: count
        filters:
          - sql: "{CUBE}.days_late > 0"

      - name: late_rate
        sql: "{CUBE.late_shipments} / NULLIF({CUBE.shipments}, 0)"
        type: number
        format: percent

      - name: avg_days_late
        sql: "{CUBE}.days_late"
        type: avg
```

**Best practice.** `avg_days_late` averages over *all* shipments including early
ones, so it reads as "average schedule slack". If you want "average lateness of
late shipments", that's a different measure with a filter — name them so the
difference is visible, because this is exactly where dashboards quietly disagree
with each other.

Also: `late_rate` is meaningless on a handful of shipments. Consider surfacing
`shipments` alongside it always, so consumers can see the denominator.

### Q8. Delivery vs. estimate, by state

**Implementation.** This one lives naturally on `orders` — both columns are on the
same row.

```yaml
# in orders.yml
dimensions:
  - name: delivery_variance_days
    type: number
    sql: >
      EXTRACT(EPOCH FROM (
        {CUBE}.order_delivered_customer_date - {CUBE}.order_estimated_delivery_date
      )) / 86400

  - name: delivery_outcome
    type: string
    sql: >
      CASE
        WHEN {CUBE}.order_delivered_customer_date IS NULL THEN 'not delivered'
        WHEN {CUBE}.order_delivered_customer_date
             <= {CUBE}.order_estimated_delivery_date THEN 'on time'
        ELSE 'late'
      END

measures:
  - name: avg_delivery_variance_days
    sql: "{CUBE.delivery_variance_days}"
    type: avg

  - name: late_deliveries
    type: count
    filters:
      - sql: >
          {CUBE}.order_delivered_customer_date
            > {CUBE}.order_estimated_delivery_date
```

**Query.** Group by `customers.customer_state` — the `many_to_one` join already
exists.

**Best practice.** Referencing `{CUBE.delivery_variance_days}` from the measure
reuses the dimension's SQL instead of duplicating the expression. When the
definition of "variance" changes, it changes in one place. This is the single
highest-value habit in Cube modelling.

Watch the NULLs: ~3% of Olist orders never delivered. `AVG` skips NULLs silently,
so `avg_delivery_variance_days` is implicitly "among delivered orders". Make that
explicit with a segment or a comment, or the number will be misread.

### Q9. Fulfillment funnel — which leg is slowest?

**Why it's hard.** Four intervals across four columns on one row. The natural
output shape is one row *per stage*, which means unpivoting.

**Implementation.** Two approaches, and the choice matters.

*Approach A — four measures.* Simple, works with any client, but stages become
columns rather than a groupable dimension:

```yaml
measures:
  - name: avg_hours_to_approval
    type: avg
    sql: >
      EXTRACT(EPOCH FROM ({CUBE}.order_approved_at
        - {CUBE}.order_purchase_timestamp)) / 3600

  - name: avg_hours_to_carrier
    type: avg
    sql: >
      EXTRACT(EPOCH FROM ({CUBE}.order_delivered_carrier_date
        - {CUBE}.order_approved_at)) / 3600

  - name: avg_hours_to_customer
    type: avg
    sql: >
      EXTRACT(EPOCH FROM ({CUBE}.order_delivered_customer_date
        - {CUBE}.order_delivered_carrier_date)) / 3600
```

*Approach B — an unpivoted stage cube.* Lets you ask "which stage is slowest"
as a genuine group-by, and sorts/filters like any other dimension:

```yaml
cubes:
  - name: fulfillment_stages
    data_source: default
    sql: >
      SELECT order_id, order_purchase_timestamp, stage, stage_hours
      FROM public.orders o
      CROSS JOIN LATERAL (VALUES
        ('1. approval',
          EXTRACT(EPOCH FROM (o.order_approved_at - o.order_purchase_timestamp))/3600),
        ('2. carrier handoff',
          EXTRACT(EPOCH FROM (o.order_delivered_carrier_date - o.order_approved_at))/3600),
        ('3. delivery',
          EXTRACT(EPOCH FROM (o.order_delivered_customer_date - o.order_delivered_carrier_date))/3600)
      ) AS s(stage, stage_hours)
      WHERE s.stage_hours IS NOT NULL

    dimensions:
      - name: id
        sql: "{CUBE}.order_id || '-' || {CUBE}.stage"
        type: string
        primary_key: true

      - name: stage
        sql: "{CUBE}.stage"
        type: string

    measures:
      - name: avg_hours
        sql: "{CUBE}.stage_hours"
        type: avg

      - name: p95_hours
        sql: "{CUBE}.stage_hours"
        type: number
        # Cube has no built-in percentile; express it directly.
        # Note: this is a non-additive measure — do not pre-aggregate it.
```

**Best practice.** Prefer B when the stages are a genuine dimension of analysis
(you want to sort by them, filter to one, chart them side by side). Prefer A when
you only ever want all four at once. Don't build both — two sources for one number
is how they drift.

Percentiles are **non-additive**: `p95` of a union is not derivable from the `p95`
of the parts. Never put one in a pre-aggregation rollup.

---

## Group 4: Ranking and windowing

Cube's query API has no `ROW_NUMBER`, `LAG`, or top-N-per-group. There are three
ways around this; pick deliberately.

### Q10. Top 3 categories by revenue within each state

**Implementation — use the SQL API.** Cube exposes a Postgres-wire endpoint on
port `15432` where the cubes appear as tables. Window functions run in the outer
query, over semantically-correct aggregates:

```bash
psql -h localhost -p 15432 -U cube
```

```sql
WITH revenue AS (
  SELECT
    customer_state,
    category,
    MEASURE(total_price) AS revenue
  FROM order_economics
  GROUP BY 1, 2
)
SELECT * FROM (
  SELECT
    customer_state,
    category,
    revenue,
    ROW_NUMBER() OVER (PARTITION BY customer_state ORDER BY revenue DESC) AS rn
  FROM revenue
) t
WHERE rn <= 3
ORDER BY customer_state, rn;
```

`MEASURE()` is required — it tells Cube to resolve the measure through the
semantic layer rather than treating it as a plain column.

**Best practice.** The inner aggregation is pushed down to Cube (and can hit a
pre-aggregation); the window function runs in Cube's own query engine on the small
result. Keep the inner `GROUP BY` as narrow as possible — everything it returns is
materialised before the window runs.

The two alternatives, for completeness:
- *Client-side ranking* — fetch all state × category rows, rank in application
  code. Fine when the grid is small (27 states × ~70 categories). No modelling
  cost.
- *A ranked cube* — bake `ROW_NUMBER()` into a cube's `sql:`. Only worth it if the
  ranking is a stable business definition, because it hardcodes the partition and
  the ordering measure.

### Q11. Top-decile sellers and their GMV share

**Why it's hard.** A percentile threshold computed across the whole population,
then a share against a global denominator — two aggregations at different scopes.

**Implementation.** Bake the percentile into a seller-grain cube, since the
decile assignment is a property of the seller:

```yaml
cubes:
  - name: seller_performance
    data_source: default
    sql: >
      SELECT
        seller_id,
        revenue,
        orders,
        NTILE(10) OVER (ORDER BY revenue DESC) AS revenue_decile,
        SUM(revenue) OVER () AS total_gmv
      FROM (
        SELECT
          seller_id,
          SUM(price)                 AS revenue,
          COUNT(DISTINCT order_id)   AS orders
        FROM public.order_items
        GROUP BY seller_id
      ) s

    dimensions:
      - name: seller_id
        sql: "{CUBE}.seller_id"
        type: string
        primary_key: true

      - name: revenue_decile
        sql: "{CUBE}.revenue_decile"
        type: number

      - name: is_top_decile
        sql: "{CUBE}.revenue_decile = 1"
        type: boolean

    measures:
      - name: sellers
        type: count

      - name: revenue
        sql: "{CUBE}.revenue"
        type: sum

      - name: gmv_share
        sql: "SUM({CUBE}.revenue) / NULLIF(MAX({CUBE}.total_gmv), 0)"
        type: number
        format: percent
```

**Best practice.** `SUM(revenue) OVER ()` carries the global total onto every row,
so `gmv_share` has a denominator that survives any filter you apply — filter to
one decile and the share is still *of total GMV*, which is what was asked. Use
`MAX()` on the constant, not `SUM()`, or the denominator multiplies by the row
count. This trick is worth remembering; getting a filter-invariant denominator is
otherwise painful.

### Q12. MoM revenue growth by category, categories with >100 orders

**Implementation.** Two independent mechanisms.

*The growth part* — Cube has `rolling_window` for trailing aggregates:

```yaml
measures:
  - name: revenue_28d
    sql: "{CUBE}.price"
    type: sum
    rolling_window:
      trailing: 28 day
      offset: end
```

For a true period-over-period *delta*, use the SQL API with `LAG`:

```sql
SELECT
  category,
  month,
  revenue,
  revenue / NULLIF(LAG(revenue) OVER (PARTITION BY category ORDER BY month), 0) - 1
    AS mom_growth
FROM (
  SELECT
    category,
    DATE_TRUNC('month', order_purchase_timestamp) AS month,
    MEASURE(total_price) AS revenue
  FROM order_economics
  GROUP BY 1, 2
) t;
```

*The >100 orders part* is a `HAVING` on a different aggregate than the one you're
ranking. Model it as a segment if the threshold is stable:

```yaml
segments:
  - name: high_volume
    sql: "{CUBE}.order_count > 100"
```

...which only works if `order_count` is a column at the cube's grain. Otherwise it
belongs in the outer SQL-API query as a real `HAVING`.

**Best practice.** Segments are named, reusable filters — much better than
consumers re-typing a threshold. But a segment is a row-level predicate, not a
post-aggregation filter. If the condition is on an aggregate, it must either come
from a pre-aggregated cube grain or live in the outer query.

---

## Group 5: Cross-table geography

### Q13. Seller-to-customer distance vs. delivery delay

**Why it's hard.** Three separate problems stacked:
1. `geolocation` has no primary key — zip prefixes repeat across thousands of
   lat/lng points. Joining it raw fans out catastrophically.
2. It has no lat/lng dimensions in the current model at all.
3. Distance is a two-point calculation across two different joins to the *same*
   cube.

**Implementation.** First, collapse geolocation to one point per zip prefix:

```yaml
cubes:
  - name: geo_points
    data_source: default
    sql: >
      SELECT
        geolocation_zip_code_prefix AS zip_prefix,
        AVG(geolocation_lat) AS lat,
        AVG(geolocation_lng) AS lng,
        MODE() WITHIN GROUP (ORDER BY geolocation_city)  AS city,
        MODE() WITHIN GROUP (ORDER BY geolocation_state) AS state
      FROM public.geolocation
      GROUP BY 1

    dimensions:
      - name: zip_prefix
        sql: "{CUBE}.zip_prefix"
        type: string
        primary_key: true

      - name: lat
        sql: "{CUBE}.lat"
        type: number

      - name: lng
        sql: "{CUBE}.lng"
        type: number
```

Then the distance cube. Two joins to `geo_points` from one row means Cube's join
graph can't help — resolve it in SQL:

```yaml
cubes:
  - name: shipping_distance
    data_source: default
    sql: >
      WITH geo AS (
        SELECT geolocation_zip_code_prefix AS zip,
               AVG(geolocation_lat) AS lat,
               AVG(geolocation_lng) AS lng
        FROM public.geolocation GROUP BY 1
      )
      SELECT
        oi.order_id,
        oi.order_item_id,
        oi.seller_id,
        o.order_purchase_timestamp,
        EXTRACT(EPOCH FROM (o.order_delivered_customer_date
          - o.order_purchase_timestamp)) / 86400 AS delivery_days,
        -- Haversine, earth radius 6371 km
        2 * 6371 * ASIN(SQRT(
            POWER(SIN(RADIANS(cg.lat - sg.lat) / 2), 2)
          + COS(RADIANS(sg.lat)) * COS(RADIANS(cg.lat))
          * POWER(SIN(RADIANS(cg.lng - sg.lng) / 2), 2)
        )) AS distance_km
      FROM public.order_items oi
      JOIN public.orders    o  ON o.order_id  = oi.order_id
      JOIN public.customers c  ON c.customer_id = o.customer_id
      JOIN public.sellers   s  ON s.seller_id = oi.seller_id
      JOIN geo sg ON sg.zip = s.seller_zip_code_prefix
      JOIN geo cg ON cg.zip = c.customer_zip_code_prefix
      WHERE o.order_delivered_customer_date IS NOT NULL

    dimensions:
      - name: id
        sql: "{CUBE}.order_id || '-' || {CUBE}.order_item_id"
        type: string
        primary_key: true

      - name: distance_band
        type: string
        sql: >
          CASE
            WHEN {CUBE}.distance_km <   50 THEN '1. under 50km'
            WHEN {CUBE}.distance_km <  200 THEN '2. 50-200km'
            WHEN {CUBE}.distance_km <  500 THEN '3. 200-500km'
            WHEN {CUBE}.distance_km < 1500 THEN '4. 500-1500km'
            ELSE '5. over 1500km'
          END

    measures:
      - name: shipments
        type: count

      - name: avg_distance_km
        sql: "{CUBE}.distance_km"
        type: avg

      - name: avg_delivery_days
        sql: "{CUBE}.delivery_days"
        type: avg

    pre_aggregations:
      - name: by_band
        measures: [shipments, avg_distance_km, avg_delivery_days]
        dimensions: [distance_band]
        time_dimension: order_purchase_timestamp
        granularity: month
```

**Query.** Group by `distance_band`, request `avg_delivery_days` and `shipments`.
The monotonic relationship is the answer.

**Best practice.** Three things worth copying:
- **Never join a keyless table directly.** Collapse it to a grain with a real
  primary key first. This is the single most common cause of silently-inflated
  numbers in a semantic layer.
- **Band continuous values into a dimension** rather than exposing the raw number
  for grouping — grouping by a float produces one row per distinct value.
- **Pre-aggregate this one.** The haversine over ~110k items with two geo joins is
  the most expensive query in the model.

---

## Group 6: Conditional aggregation

### Q14. Do more instalments correlate with worse reviews?

**Why it's hard.** `order_payments` and `order_reviews` are both facts hanging off
`orders`. Same fan-out as [Q1](#q1-item-revenue-vs-payment-value-per-month) — and
here it's worse, because instalment count is the thing you're grouping *by*, so
the inflation is correlated with the grouping variable. The bias won't look like
noise.

**Implementation.** Flatten to order grain, where both facts have exactly one
value per order:

```yaml
cubes:
  - name: order_payment_reviews
    data_source: default
    sql: >
      SELECT
        o.order_id,
        o.order_purchase_timestamp,
        p.max_installments,
        p.paid,
        p.payment_types,
        r.review_score
      FROM public.orders o
      JOIN (
        SELECT
          order_id,
          MAX(payment_installments) AS max_installments,
          SUM(payment_value)        AS paid,
          STRING_AGG(DISTINCT payment_type, ',' ORDER BY payment_type) AS payment_types
        FROM public.order_payments
        GROUP BY order_id
      ) p ON p.order_id = o.order_id
      JOIN (
        SELECT DISTINCT ON (order_id) order_id, review_score
        FROM public.order_reviews
        ORDER BY order_id, review_answer_timestamp DESC
      ) r ON r.order_id = o.order_id

    dimensions:
      - name: order_id
        sql: "{CUBE}.order_id"
        type: string
        primary_key: true

      - name: installment_band
        type: string
        sql: >
          CASE
            WHEN {CUBE}.max_installments <= 1 THEN '1. single payment'
            WHEN {CUBE}.max_installments <= 3 THEN '2. 2-3x'
            WHEN {CUBE}.max_installments <= 6 THEN '3. 4-6x'
            WHEN {CUBE}.max_installments <= 12 THEN '4. 7-12x'
            ELSE '5. 12x+'
          END

      - name: payment_types
        sql: "{CUBE}.payment_types"
        type: string

    measures:
      - name: orders
        type: count

      - name: avg_review_score
        sql: "{CUBE}.review_score"
        type: avg

      - name: detractors
        type: count
        filters:
          - sql: "{CUBE}.review_score <= 2"

      - name: detractor_rate
        sql: "{CUBE.detractors} / NULLIF({CUBE.orders}, 0)"
        type: number
        format: percent

      - name: avg_order_value
        sql: "{CUBE}.paid"
        type: avg
```

**Best practice.** Return `avg_order_value` alongside the review metrics. High
instalment counts correlate with expensive orders, which correlate with heavier
freight and longer delivery — the confounder is visible only if the model surfaces
it. A semantic layer that makes confounders easy to see is doing its job.

Note `MAX(payment_installments)` is a modelling *decision*, not a fact — an order
split across a 10× credit card payment and a voucher has an ambiguous "instalment
count". Document choices like this in the cube `description`.

### Q15. Worst review scores relative to price band

**Why it's hard.** Price quintiles are computed globally across all items, then
compared *within* each category — a global window feeding a grouped comparison.

**Implementation.**

```yaml
cubes:
  - name: item_price_quality
    data_source: default
    sql: >
      SELECT
        oi.order_id,
        oi.order_item_id,
        oi.price,
        NTILE(5) OVER (ORDER BY oi.price) AS price_quintile,
        COALESCE(t.product_category_name_english, p.product_category_name) AS category,
        r.review_score
      FROM public.order_items oi
      JOIN public.products p ON p.product_id = oi.product_id
      LEFT JOIN public.product_category_name_translation t
        ON t.product_category_name = p.product_category_name
      JOIN (
        SELECT DISTINCT ON (order_id) order_id, review_score
        FROM public.order_reviews
        ORDER BY order_id, review_answer_timestamp DESC
      ) r ON r.order_id = oi.order_id

    dimensions:
      - name: id
        sql: "{CUBE}.order_id || '-' || {CUBE}.order_item_id"
        type: string
        primary_key: true

      - name: category
        sql: "{CUBE}.category"
        type: string

      - name: price_quintile
        sql: "{CUBE}.price_quintile"
        type: number

    measures:
      - name: items
        type: count

      - name: avg_review_score
        sql: "{CUBE}.review_score"
        type: avg
```

Then in the SQL API, compare each category to its quintile's baseline:

```sql
WITH cat AS (
  SELECT category, price_quintile,
         MEASURE(avg_review_score) AS score,
         MEASURE(items) AS items
  FROM item_price_quality GROUP BY 1, 2
)
SELECT
  category, price_quintile, score, items,
  score - AVG(score) OVER (PARTITION BY price_quintile) AS vs_band_baseline
FROM cat
WHERE items >= 50
ORDER BY vs_band_baseline ASC
LIMIT 20;
```

**Best practice.** The `WHERE items >= 50` guard is essential. Categories with a
handful of items dominate any "worst average" ranking through variance alone.
Whenever you rank by an average, filter by the count — and show the count in the
output so the reader can judge for themselves.

---

## Best practices summary

**Modelling**

1. Qualify every column reference with `{CUBE}`. No exceptions.
2. Declare joins in both directions when the cube is a hub. `relationship` drives
   correctness, not just documentation.
3. Every cube needs a primary key at its true grain. If the source table has no
   unique key, build the cube over a `sql:` query that establishes one.
4. When a metric's grain doesn't match any physical table, create a cube at that
   grain. Don't patch fan-out downstream.
5. Reference measures from measures (`{CUBE.other_measure}`) and dimensions from
   measures (`{CUBE.some_dimension}`). Never duplicate an expression.
6. Band continuous values into string dimensions. Grouping by a float gives one
   row per value.

**Correctness**

7. Two fact cubes in one query means a view with explicit `join_path`s, or a
   pre-flattened cube. Check the generated SQL for a `FULL OUTER JOIN` of
   subqueries.
8. Ratios are `SUM(a)/SUM(b)`, never `AVG(a/b)`. Always `NULLIF` the denominator.
9. Always publish the denominator next to a rate, and filter low-count groups
   before ranking by an average.
10. Percentiles and `count_distinct` are non-additive — keep them out of rollup
    pre-aggregations.
11. `AVG` skips NULLs silently. State which population a metric covers.

**Where logic belongs**

12. Row-level filters → `segments`. Conditional counts → measure `filters:`.
    Filters on aggregates → outer SQL-API query or a pre-aggregated cube grain.
13. Window functions (rank, lag, top-N-per-group) → the SQL API on port 15432,
    with `MEASURE()` around measure references. Bake them into a cube's `sql:`
    only when the definition is stable business logic.
14. Push expensive thresholds (`HAVING`) into the cube SQL, not the query — a
    query filter runs after the expensive join.

**Operations**

15. Pre-aggregate the expensive cubes: `product_affinity`, `shipping_distance`.
    Pre-aggregations must be defined over additive measures.
16. Use `description:` on any cube or measure that encodes a judgement call
    (`MAX(installments)`, "most recent review wins", "delivered orders only").
    Consumers — human and agent — read those.
17. Verify with `/cubejs-api/v1/sql`, which compiles without executing. It works
    even when the query errors, and it's the fastest way to spot a fan-out.
