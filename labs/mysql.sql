-- Database Index Lab - MySQL 8.0.18+ / InnoDB
--
-- EXPLAIN ANALYZE requires MySQL 8.0.18 or newer. On MySQL 8.0.17 and older,
-- comment out the EXPLAIN ANALYZE statements and use the preceding EXPLAIN.
-- MariaDB has different syntax and is not a target of this script.
--
-- This is pure MySQL SQL. Open it in MySQL Workbench, DBeaver, DataGrip, or
-- another SQL console that supports multi-statement scripts, then choose
-- Execute Script / Run All. No mysql client commands are required.
--
-- Edit the two SET values below to change the generated data volume.
-- Supported order_count range: 1 to 1,000,000 (the row generator has 6 digits).
-- tenant_count must be a positive integer. Defaults: 1,000,000 orders and 100 tenants.
-- The account needs CREATE DATABASE and table/index DDL permissions. The script
-- recreates only tables in the dedicated db_index_lab database.
-- Exact plans and timings vary by hardware, cache state, settings, and data.

SET @order_count = 1000000;
SET @tenant_count = 100;

CREATE DATABASE IF NOT EXISTS db_index_lab
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_0900_ai_ci;
USE db_index_lab;

DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS lab_digits;

CREATE TABLE lab_digits (
    n tinyint unsigned NOT NULL PRIMARY KEY
) ENGINE = InnoDB;

INSERT INTO lab_digits (n)
VALUES (0), (1), (2), (3), (4), (5), (6), (7), (8), (9);

CREATE TABLE orders (
    id             bigint unsigned NOT NULL,
    tenant_id      int unsigned NOT NULL,
    user_id        bigint unsigned NOT NULL,
    status         enum('NEW', 'PAID', 'SHIPPED', 'CANCELLED', 'REFUNDED') NOT NULL,
    total_cents    bigint unsigned NOT NULL,
    created_at     datetime(6) NOT NULL,
    updated_at     datetime(6) NOT NULL,
    deleted_at     datetime(6) NULL,
    metadata       json NOT NULL,
    PRIMARY KEY (id)
) ENGINE = InnoDB;

-- Six crossed digit tables generate integers 1 through 1,000,000 without
-- increasing cte_max_recursion_depth. created_at rises with id, keeping
-- the clustered table physically correlated with time for this lab.
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
    1 + MOD(g - 1, @tenant_count) AS tenant_id,
    1 + MOD(g * 7919, 200000) AS user_id,
    CASE
        WHEN MOD(FLOOR((g - 1) / @tenant_count), 100) < 5 THEN 'NEW'
        WHEN MOD(FLOOR((g - 1) / @tenant_count), 100) < 75 THEN 'PAID'
        WHEN MOD(FLOOR((g - 1) / @tenant_count), 100) < 87 THEN 'SHIPPED'
        WHEN MOD(FLOOR((g - 1) / @tenant_count), 100) < 95 THEN 'CANCELLED'
        ELSE 'REFUNDED'
    END AS status,
    1000 + MOD(g, 500000) AS total_cents,
    TIMESTAMPADD(
        SECOND,
        FLOOR((g - 1) * 63072000 / GREATEST(@order_count - 1, 1)),
        TIMESTAMP('2024-01-01 00:00:00')
    ) AS created_at,
    TIMESTAMPADD(
        MINUTE,
        MOD(g, 240),
        TIMESTAMPADD(
            SECOND,
            FLOOR((g - 1) * 63072000 / GREATEST(@order_count - 1, 1)),
            TIMESTAMP('2024-01-01 00:00:00')
        )
    ) AS updated_at,
    CASE
        WHEN MOD(g, 50) = 0 THEN
            TIMESTAMPADD(
                DAY,
                7,
                TIMESTAMPADD(
                    SECOND,
                    FLOOR((g - 1) * 63072000 / GREATEST(@order_count - 1, 1)),
                    TIMESTAMP('2024-01-01 00:00:00')
                )
            )
        ELSE NULL
    END AS deleted_at,
    JSON_OBJECT(
        'channel', ELT(1 + MOD(g - 1, 3), 'web', 'mobile', 'partner'),
        'region', ELT(1 + MOD(g - 1, 4), 'north', 'south', 'east', 'west'),
        'priority', IF(
            MOD(g, 997) = 0,
            JSON_EXTRACT('true', '$'),
            JSON_EXTRACT('false', '$')
        ),
        'customer_email', CONCAT('user', 1 + MOD(g * 7919, 200000), '@example.com'),
        'external_ref', CONCAT('ORD-', LPAD(g, 12, '0')),
        'note', CONCAT('lab-order-', g, '-', REPEAT('x', MOD(g, 40)))
    ) AS metadata
FROM (
    SELECT
        1 + d0.n
          + 10 * d1.n
          + 100 * d2.n
          + 1000 * d3.n
          + 10000 * d4.n
          + 100000 * d5.n AS g
    FROM lab_digits AS d0
    CROSS JOIN lab_digits AS d1
    CROSS JOIN lab_digits AS d2
    CROSS JOIN lab_digits AS d3
    CROSS JOIN lab_digits AS d4
    CROSS JOIN lab_digits AS d5
) AS seq
WHERE g <= @order_count;

DROP TABLE lab_digits;
ANALYZE TABLE orders;

SELECT
    COUNT(*) AS rows_loaded,
    COUNT(DISTINCT tenant_id) AS tenants,
    MIN(created_at) AS first_order,
    MAX(created_at) AS last_order
FROM orders;

-- ---------------------------------------------------------------------------
-- Case 1: the PRIMARY KEY is the InnoDB clustered index
-- ---------------------------------------------------------------------------
-- The whole row lives with the primary-key leaf record. A primary-key range is
-- therefore a clustered range scan, not a secondary-index lookup plus a second
-- lookup into a separate heap.

EXPLAIN
SELECT *
FROM orders
WHERE id BETWEEN FLOOR(@order_count / 2) AND FLOOR(@order_count / 2) + 50;

EXPLAIN ANALYZE
SELECT *
FROM orders
WHERE id BETWEEN FLOOR(@order_count / 2) AND FLOOR(@order_count / 2) + 50;

-- ---------------------------------------------------------------------------
-- Case 2: a secondary index stores its key plus the primary key
-- ---------------------------------------------------------------------------
-- Fetching columns absent from idx_orders_tenant_id requires InnoDB to use the
-- primary key stored in each matching secondary leaf entry to fetch base rows.

CREATE INDEX idx_orders_tenant_id ON orders (tenant_id);
ANALYZE TABLE orders;

EXPLAIN
SELECT id, user_id, status, total_cents, created_at
FROM orders
WHERE tenant_id = LEAST(42, @tenant_count)
  AND status = 'PAID'
  AND created_at >= '2025-01-01 00:00:00'
  AND created_at <  '2026-01-01 00:00:00'
ORDER BY created_at DESC, id DESC
LIMIT 50;

EXPLAIN ANALYZE
SELECT id, user_id, status, total_cents, created_at
FROM orders
WHERE tenant_id = LEAST(42, @tenant_count)
  AND status = 'PAID'
  AND created_at >= '2025-01-01 00:00:00'
  AND created_at <  '2026-01-01 00:00:00'
ORDER BY created_at DESC, id DESC
LIMIT 50;

DROP INDEX idx_orders_tenant_id ON orders;

-- ---------------------------------------------------------------------------
-- Case 3: a compound secondary index aligns filtering and ordering
-- ---------------------------------------------------------------------------
-- InnoDB silently carries the primary key in every secondary entry. id is
-- explicit here because its descending order is part of the endpoint contract.

CREATE INDEX idx_orders_list
    ON orders (tenant_id, status, created_at DESC, id DESC);
ANALYZE TABLE orders;

EXPLAIN
SELECT id, user_id, status, total_cents, created_at
FROM orders
WHERE tenant_id = LEAST(42, @tenant_count)
  AND status = 'PAID'
  AND created_at >= '2025-01-01 00:00:00'
  AND created_at <  '2026-01-01 00:00:00'
ORDER BY created_at DESC, id DESC
LIMIT 50;

EXPLAIN ANALYZE
SELECT id, user_id, status, total_cents, created_at
FROM orders
WHERE tenant_id = LEAST(42, @tenant_count)
  AND status = 'PAID'
  AND created_at >= '2025-01-01 00:00:00'
  AND created_at <  '2026-01-01 00:00:00'
ORDER BY created_at DESC, id DESC
LIMIT 50;

-- ---------------------------------------------------------------------------
-- Case 4: MySQL has no PostgreSQL-style INCLUDE clause
-- ---------------------------------------------------------------------------
-- To make this query covering, projected columns become trailing key columns.
-- This can avoid clustered lookups, but it also makes every leaf entry larger.

DROP INDEX idx_orders_list ON orders;
CREATE INDEX idx_orders_list_covering
    ON orders (
        tenant_id,
        status,
        created_at DESC,
        id DESC,
        user_id,
        total_cents
    );
ANALYZE TABLE orders;

EXPLAIN
SELECT id, user_id, status, total_cents, created_at
FROM orders
WHERE tenant_id = LEAST(42, @tenant_count)
  AND status = 'PAID'
  AND created_at >= '2025-01-01 00:00:00'
  AND created_at <  '2026-01-01 00:00:00'
ORDER BY created_at DESC, id DESC
LIMIT 50;

EXPLAIN ANALYZE
SELECT id, user_id, status, total_cents, created_at
FROM orders
WHERE tenant_id = LEAST(42, @tenant_count)
  AND status = 'PAID'
  AND created_at >= '2025-01-01 00:00:00'
  AND created_at <  '2026-01-01 00:00:00'
ORDER BY created_at DESC, id DESC
LIMIT 50;

SHOW INDEX FROM orders;

SELECT
    table_rows AS estimated_rows,
    ROUND(data_length / 1024 / 1024, 1) AS clustered_data_mb,
    ROUND(index_length / 1024 / 1024, 1) AS secondary_indexes_mb
FROM information_schema.tables
WHERE table_schema = 'db_index_lab'
  AND table_name = 'orders';

SELECT 'Lab complete; objects kept in database db_index_lab.' AS message;

-- Explicit cleanup (disabled by default). Remove the comment only when the
-- dedicated lab database and all of its contents are no longer needed:
-- DROP DATABASE db_index_lab;
