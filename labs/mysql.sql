-- 数据库索引实验 - MySQL 8.0.18+ / InnoDB
--
-- EXPLAIN ANALYZE 需要 MySQL 8.0.18 或更高版本。如果使用 MySQL 8.0.17
-- 或更早版本，请注释掉 EXPLAIN ANALYZE 语句，改用其前面的 EXPLAIN。
-- MariaDB 的语法不同，不在本脚本的适用范围内。
--
-- 本文件仅包含标准 MySQL SQL。请在 MySQL Workbench、DBeaver、DataGrip
-- 或其他支持多语句脚本的 SQL 控制台中打开，然后选择“执行脚本”或“全部运行”。
-- 无需使用任何 mysql 客户端命令。
--
-- 修改下面两个 SET 值可调整生成的数据量。
-- order_count 支持的范围为 1 到 1,000,000（行生成器使用 6 位数字）。
-- tenant_count 必须是正整数。默认生成 1,000,000 条订单，包含 100 个租户。
-- 执行账户需要 CREATE DATABASE 以及表和索引的 DDL 权限。本脚本只会在
-- 专用的 db_index_lab 数据库中重建表。
-- 实际执行计划和耗时会因硬件、缓存状态、配置及数据而异。

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

-- 通过 6 个数字表的笛卡尔积生成 1 到 1,000,000 的整数，无需提高
-- cte_max_recursion_depth。created_at 随 id 递增，使本实验中的聚簇表
-- 在物理存储上与时间保持相关。
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
-- 场景 1：PRIMARY KEY 是 InnoDB 的聚簇索引
-- ---------------------------------------------------------------------------
-- 完整的数据行存储在主键叶子记录中。因此，主键范围查询执行的是聚簇索引
-- 范围扫描，而不是先查二级索引，再到独立的堆表中进行第二次查找。

EXPLAIN
SELECT *
FROM orders
WHERE id BETWEEN FLOOR(@order_count / 2) AND FLOOR(@order_count / 2) + 50;

EXPLAIN ANALYZE
SELECT *
FROM orders
WHERE id BETWEEN FLOOR(@order_count / 2) AND FLOOR(@order_count / 2) + 50;

-- ---------------------------------------------------------------------------
-- 场景 2：二级索引同时存储自身的键和主键
-- ---------------------------------------------------------------------------
-- 查询 idx_orders_tenant_id 中未包含的列时，InnoDB 需要使用每条匹配的
-- 二级索引叶子记录中存储的主键，再回到聚簇索引中获取完整数据行。

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
-- 场景 3：复合二级索引同时匹配筛选和排序需求
-- ---------------------------------------------------------------------------
-- InnoDB 会在每条二级索引记录中隐式携带主键。这里显式加入 id，是因为
-- 接口约定要求它按降序排列。

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
-- 场景 4：MySQL 没有 PostgreSQL 风格的 INCLUDE 子句
-- ---------------------------------------------------------------------------
-- 为了让索引覆盖此查询，需要将查询返回的列作为索引末尾的键列。
-- 这样可以避免回查聚簇索引，但也会增大每条叶子记录。

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

-- 显式清理（默认禁用）。仅当确定不再需要专用实验数据库及其中的全部内容时，
-- 才取消下一行的注释：
-- DROP DATABASE db_index_lab;
