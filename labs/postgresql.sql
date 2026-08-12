-- Database Index Lab - PostgreSQL 14+
--
-- This is pure PostgreSQL SQL. Open it in pgAdmin, DBeaver, DataGrip, psql, or
-- another SQL console that supports multi-statement scripts, then choose
-- Execute Script / Run All. No psql meta-commands or client-side variables are
-- required.
--
-- Edit the three SET values below to change the data volume or inspected tenant.
-- Defaults: 1,000,000 orders, 100 tenants, and tenant 42.
-- order_count and tenant_count must be positive integers; target_tenant must be
-- between 1 and tenant_count.
-- The account needs CREATE permission on the current database and ownership of
-- an existing db_index_lab schema. The script drops and recreates only that
-- dedicated schema; do not reuse this schema name for real data.
-- Runtime and exact plans depend on hardware, cache state, table size, settings,
-- and data distribution. Compare plan shape and buffer usage, not wall time alone.

SET db_index_lab.order_count = '1000000';
SET db_index_lab.tenant_count = '100';
SET db_index_lab.target_tenant = '42';

SELECT format(
    'Configuration: order_count=%s, tenant_count=%s, target_tenant=%s',
    current_setting('db_index_lab.order_count'),
    current_setting('db_index_lab.tenant_count'),
    current_setting('db_index_lab.target_tenant')
) AS lab_step;

SELECT 'Recreating the dedicated db_index_lab schema...' AS lab_step;

DROP SCHEMA IF EXISTS db_index_lab CASCADE;
CREATE SCHEMA db_index_lab;
SET search_path = db_index_lab, pg_catalog;
SET application_name = 'database-index-lab';
-- JIT startup can hide the indexing lesson on small lab data sets.
SET jit = off;

CREATE TABLE orders (
    id             bigint PRIMARY KEY,
    tenant_id      integer NOT NULL,
    user_id        bigint NOT NULL,
    status         text NOT NULL CHECK (status IN ('NEW', 'PAID', 'SHIPPED', 'CANCELLED', 'REFUNDED')),
    total_cents    bigint NOT NULL CHECK (total_cents >= 0),
    created_at     timestamptz NOT NULL,
    updated_at     timestamptz NOT NULL,
    deleted_at     timestamptz,
    metadata       jsonb NOT NULL
);

SELECT 'Loading deterministic, time-correlated order data...' AS lab_step;

INSERT INTO orders (
    id,
    tenant_id,
    user_id,
    status,
    total_cents,
    created_at,
    updated_at,
    deleted_at,
    metadata
)
SELECT
    g AS id,
    1 + ((g - 1) % current_setting('db_index_lab.tenant_count')::bigint)::integer AS tenant_id,
    1 + ((g * 7919) % 200000) AS user_id,
    CASE
        WHEN (((g - 1) / current_setting('db_index_lab.tenant_count')::bigint) % 100) < 5 THEN 'NEW'
        WHEN (((g - 1) / current_setting('db_index_lab.tenant_count')::bigint) % 100) < 75 THEN 'PAID'
        WHEN (((g - 1) / current_setting('db_index_lab.tenant_count')::bigint) % 100) < 87 THEN 'SHIPPED'
        WHEN (((g - 1) / current_setting('db_index_lab.tenant_count')::bigint) % 100) < 95 THEN 'CANCELLED'
        ELSE 'REFUNDED'
    END AS status,
    1000 + (g % 500000) AS total_cents,
    TIMESTAMPTZ '2024-01-01 00:00:00+00'
        + INTERVAL '730 days'
          * ((g - 1)::double precision
             / GREATEST(current_setting('db_index_lab.order_count')::bigint - 1, 1)::double precision) AS created_at,
    TIMESTAMPTZ '2024-01-01 00:00:00+00'
        + INTERVAL '730 days'
          * ((g - 1)::double precision
             / GREATEST(current_setting('db_index_lab.order_count')::bigint - 1, 1)::double precision)
        + INTERVAL '1 minute' * (g % 240)::double precision AS updated_at,
    CASE
        WHEN g % 50 = 0 THEN
            TIMESTAMPTZ '2024-01-01 00:00:00+00'
                + INTERVAL '730 days'
                  * ((g - 1)::double precision
                     / GREATEST(current_setting('db_index_lab.order_count')::bigint - 1, 1)::double precision)
                + INTERVAL '7 days'
        ELSE NULL
    END AS deleted_at,
    jsonb_build_object(
        'channel', (ARRAY['web', 'mobile', 'partner'])[((g - 1) % 3)::integer + 1],
        'region', (ARRAY['north', 'south', 'east', 'west'])[((g - 1) % 4)::integer + 1],
        'priority', (g % 997 = 0),
        'customer_email', format('user%s@example.com', 1 + ((g * 7919) % 200000)),
        'external_ref', format('ORD-%s', lpad(g::text, 12, '0')),
        'note', 'lab-order-' || g || '-' || repeat('x', (g % 40)::integer)
    ) AS metadata
FROM generate_series(
    1,
    current_setting('db_index_lab.order_count')::bigint
) AS series(g)
-- Make heap/time correlation explicit so the BRIN experiment is reproducible.
ORDER BY g;

-- Keep the execute-all script transaction-safe for SQL consoles. VACUUM cannot
-- run inside a transaction block, so use ANALYZE here. After this script commits,
-- the optional VACUUM command at the end can mark heap pages all-visible and
-- reduce Heap Fetches in the covering-index experiment.
ANALYZE orders;

SELECT
    count(*) AS rows_loaded,
    count(DISTINCT tenant_id) AS tenants,
    min(created_at) AS first_order,
    max(created_at) AS last_order,
    pg_size_pretty(pg_total_relation_size('orders')) AS table_and_primary_key_size
FROM orders;

-- ---------------------------------------------------------------------------
-- Case 1: no useful index for the order-list endpoint
-- ---------------------------------------------------------------------------
-- This endpoint filters one tenant and status, limits a time range, then asks
-- for newest orders. Expect a sequential scan (possibly parallel) and a sort.

SELECT 'CASE 1 - Baseline: no useful order-list index' AS lab_step;
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, user_id, status, total_cents, created_at
FROM orders
WHERE tenant_id = current_setting('db_index_lab.target_tenant')::integer
  AND status = 'PAID'
  AND created_at >= TIMESTAMPTZ '2025-01-01 00:00:00+00'
  AND created_at <  TIMESTAMPTZ '2026-01-01 00:00:00+00'
ORDER BY created_at DESC, id DESC
LIMIT 50;

-- ---------------------------------------------------------------------------
-- Case 2: a single-column index helps filtering, but not the whole request
-- ---------------------------------------------------------------------------

SELECT 'CASE 2 - Single-column B-tree on tenant_id' AS lab_step;
CREATE INDEX idx_orders_tenant_id ON orders (tenant_id);
ANALYZE orders;

EXPLAIN (ANALYZE, BUFFERS)
SELECT id, user_id, status, total_cents, created_at
FROM orders
WHERE tenant_id = current_setting('db_index_lab.target_tenant')::integer
  AND status = 'PAID'
  AND created_at >= TIMESTAMPTZ '2025-01-01 00:00:00+00'
  AND created_at <  TIMESTAMPTZ '2026-01-01 00:00:00+00'
ORDER BY created_at DESC, id DESC
LIMIT 50;

SELECT pg_size_pretty(pg_relation_size('idx_orders_tenant_id')) AS single_index_size;

-- Remove the weaker index so the next plan is easy to interpret. In a real
-- system, validate usage before dropping an index.
DROP INDEX idx_orders_tenant_id;

-- ---------------------------------------------------------------------------
-- Case 3: equality columns first, then range/order columns
-- ---------------------------------------------------------------------------
-- tenant_id and status are equality predicates. created_at and id match
-- the requested order, so PostgreSQL can stop after it finds 50 matching rows.

SELECT 'CASE 3 - Compound B-tree aligned with filter and order' AS lab_step;
CREATE INDEX idx_orders_list
    ON orders (tenant_id, status, created_at DESC, id DESC);
ANALYZE orders;

EXPLAIN (ANALYZE, BUFFERS)
SELECT id, user_id, status, total_cents, created_at
FROM orders
WHERE tenant_id = current_setting('db_index_lab.target_tenant')::integer
  AND status = 'PAID'
  AND created_at >= TIMESTAMPTZ '2025-01-01 00:00:00+00'
  AND created_at <  TIMESTAMPTZ '2026-01-01 00:00:00+00'
ORDER BY created_at DESC, id DESC
LIMIT 50;

SELECT pg_size_pretty(pg_relation_size('idx_orders_list')) AS compound_index_size;

-- ---------------------------------------------------------------------------
-- Case 4: INCLUDE makes the endpoint eligible for an Index Only Scan
-- ---------------------------------------------------------------------------
-- INCLUDE columns are stored in leaf tuples but do not participate in search
-- order. They make the index larger and increase write cost, so include only
-- stable columns that a hot query really needs.

SELECT 'CASE 4 - Covering B-tree with INCLUDE' AS lab_step;
DROP INDEX idx_orders_list;
CREATE INDEX idx_orders_list_covering
    ON orders (tenant_id, status, created_at DESC, id DESC)
    INCLUDE (user_id, total_cents);
ANALYZE orders;

EXPLAIN (ANALYZE, BUFFERS)
SELECT id, user_id, status, total_cents, created_at
FROM orders
WHERE tenant_id = current_setting('db_index_lab.target_tenant')::integer
  AND status = 'PAID'
  AND created_at >= TIMESTAMPTZ '2025-01-01 00:00:00+00'
  AND created_at <  TIMESTAMPTZ '2026-01-01 00:00:00+00'
ORDER BY created_at DESC, id DESC
LIMIT 50;

SELECT pg_size_pretty(pg_relation_size('idx_orders_list_covering')) AS covering_index_size;

-- ---------------------------------------------------------------------------
-- Case 5: a partial index for the small, operational hot set
-- ---------------------------------------------------------------------------
-- The query predicate must imply the index predicate. Parameterized SQL whose
-- predicate cannot be proven at planning time may not use a partial index.

SELECT 'CASE 5 - Partial index for active NEW orders' AS lab_step;
DROP INDEX idx_orders_list_covering;
CREATE INDEX idx_orders_new_queue
    ON orders (tenant_id, created_at DESC, id DESC)
    INCLUDE (user_id, total_cents)
    WHERE deleted_at IS NULL AND status = 'NEW';
ANALYZE orders;

EXPLAIN (ANALYZE, BUFFERS)
SELECT id, user_id, created_at, total_cents
FROM orders
WHERE tenant_id = current_setting('db_index_lab.target_tenant')::integer
  AND deleted_at IS NULL
  AND status = 'NEW'
ORDER BY created_at DESC, id DESC
LIMIT 50;

SELECT pg_size_pretty(pg_relation_size('idx_orders_new_queue')) AS partial_index_size;

-- ---------------------------------------------------------------------------
-- Case 6: expression index for the expression used by the predicate
-- ---------------------------------------------------------------------------
-- customer_email lives inside canonical metadata. The query expression and
-- indexed expression must match for this expression index to be useful.

SELECT 'CASE 6 - Expression index for case-insensitive email lookup' AS lab_step;
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, tenant_id, created_at
FROM orders
WHERE lower(metadata ->> 'customer_email') = 'user4242@example.com'
ORDER BY id;

CREATE INDEX idx_orders_lower_customer_email
    ON orders (lower(metadata ->> 'customer_email'));
ANALYZE orders;

EXPLAIN (ANALYZE, BUFFERS)
SELECT id, tenant_id, created_at
FROM orders
WHERE lower(metadata ->> 'customer_email') = 'user4242@example.com'
ORDER BY id;

-- ---------------------------------------------------------------------------
-- Case 7: GIN for JSONB containment
-- ---------------------------------------------------------------------------
-- jsonb_path_ops is compact and focused on @> containment. Use the default
-- jsonb_ops class when operators such as key existence (?, ?|, ?&) are needed.

SELECT 'CASE 7 - JSONB containment before and after a GIN index' AS lab_step;
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*)
FROM orders
WHERE metadata @> '{"priority": true}'::jsonb;

CREATE INDEX idx_orders_metadata_gin
    ON orders USING gin (metadata jsonb_path_ops);
ANALYZE orders;

EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*)
FROM orders
WHERE metadata @> '{"priority": true}'::jsonb;

-- ---------------------------------------------------------------------------
-- Case 8: BRIN for a very large, physically time-correlated table
-- ---------------------------------------------------------------------------
-- The load order follows created_at, so page ranges have narrow min/max values.
-- BRIN is tiny and lossy: it narrows heap ranges, then rechecks rows. If the
-- heap is not correlated with created_at, the same BRIN can be ineffective.

SELECT 'CASE 8 - Narrow time range before and after a BRIN index' AS lab_step;
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*)
FROM orders
WHERE created_at >= TIMESTAMPTZ '2025-12-01 00:00:00+00'
  AND created_at <  TIMESTAMPTZ '2025-12-02 00:00:00+00';

CREATE INDEX idx_orders_created_at_brin
    ON orders USING brin (created_at) WITH (pages_per_range = 32);
ANALYZE orders;

EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*)
FROM orders
WHERE created_at >= TIMESTAMPTZ '2025-12-01 00:00:00+00'
  AND created_at <  TIMESTAMPTZ '2025-12-02 00:00:00+00';

-- Compare the indexes retained by the staged lab. Earlier size queries captured
-- the temporary single-column, compound, and covering B-tree indexes.
SELECT
    indexrelname AS index_name,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
    idx_scan
FROM pg_stat_user_indexes
WHERE schemaname = 'db_index_lab'
  AND relname = 'orders'
ORDER BY pg_relation_size(indexrelid) DESC, indexrelname;

SELECT 'Lab complete; objects kept in schema db_index_lab for inspection.' AS lab_step;

RESET search_path;
RESET application_name;
RESET jit;

-- Optional follow-up: execute this statement separately after the script has
-- committed, then rerun Case 4 to inspect visibility-map-driven Heap Fetches:
-- VACUUM (ANALYZE) db_index_lab.orders;

-- Optional cleanup (disabled by default):
-- DROP SCHEMA db_index_lab CASCADE;
