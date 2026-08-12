-- 数据库索引实验 - PostgreSQL 14+
--
-- 本文件为纯 PostgreSQL SQL。请使用 pgAdmin、DBeaver、DataGrip、psql 或
-- 其他支持多语句脚本的 SQL 控制台打开，然后选择“执行脚本”或“全部运行”。
-- 无需使用 psql 元命令或客户端变量。
--
-- 修改下面三个 SET 值即可调整数据量或要检查的租户。
-- 默认值：1,000,000 笔订单、100 个租户，以及租户 42。
-- order_count 和 tenant_count 必须为正整数；target_tenant 必须介于 1 和
-- tenant_count 之间。
-- 执行账号需要拥有当前数据库的 CREATE 权限；如果 db_index_lab 模式已存在，
-- 还需要拥有该模式。脚本只会删除并重建这个专用模式；请勿将此模式名用于真实数据。
-- 运行时间和具体执行计划取决于硬件、缓存状态、表大小、配置和数据分布。
-- 请比较执行计划的结构和缓冲区使用情况，不要只比较实际耗时。

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
-- 对于较小的实验数据集，JIT 启动开销可能掩盖索引带来的效果。
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
-- 明确保持堆表与时间的相关性，使 BRIN 实验可以稳定复现。
ORDER BY g;

-- 确保 SQL 控制台“全部运行”时，脚本可安全地在事务中执行。VACUUM 不能在
-- 事务块中运行，因此此处使用 ANALYZE。脚本提交后，可以执行末尾的可选
-- VACUUM 命令，将堆页面标记为全部可见，从而减少覆盖索引实验中的堆获取次数。
ANALYZE orders;

SELECT
    count(*) AS rows_loaded,
    count(DISTINCT tenant_id) AS tenants,
    min(created_at) AS first_order,
    max(created_at) AS last_order,
    pg_size_pretty(pg_total_relation_size('orders')) AS table_and_primary_key_size
FROM orders;

-- ---------------------------------------------------------------------------
-- 场景 1：订单列表接口没有可用的索引
-- ---------------------------------------------------------------------------
-- 该接口按单个租户和状态筛选，限定时间范围，再获取最新订单。
-- 预计会出现顺序扫描（可能为并行扫描）和排序操作。

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
-- 场景 2：单列索引有助于筛选，但不能满足整个查询
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

-- 删除效果较弱的索引，便于解读下一个执行计划。在真实系统中，删除索引前应先
-- 确认其使用情况。
DROP INDEX idx_orders_tenant_id;

-- ---------------------------------------------------------------------------
-- 场景 3：等值条件列在前，范围和排序列在后
-- ---------------------------------------------------------------------------
-- tenant_id 和 status 是等值条件。created_at 和 id 与所需排序一致，
-- 因此 PostgreSQL 找到 50 行匹配数据后即可停止扫描。

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
-- 场景 4：使用 INCLUDE 使接口查询具备仅索引扫描的条件
-- ---------------------------------------------------------------------------
-- INCLUDE 列存储在叶子元组中，但不参与搜索排序。它们会增大索引并提高写入
-- 成本，因此只应包含高频查询确实需要且相对稳定的列。

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
-- 场景 5：为较小的业务热点数据集创建部分索引
-- ---------------------------------------------------------------------------
-- 查询条件必须能够推出索引条件。如果参数化 SQL 的条件在规划阶段无法确定，
-- 则可能无法使用部分索引。

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
-- 场景 6：为查询条件中的表达式创建表达式索引
-- ---------------------------------------------------------------------------
-- customer_email 存储在规范化的 metadata 中。查询表达式必须与索引表达式匹配，
-- 才能有效使用该表达式索引。

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
-- 场景 7：使用 GIN 加速 JSONB 包含查询
-- ---------------------------------------------------------------------------
-- jsonb_path_ops 更紧凑，专用于 @> 包含查询。如需使用键存在性运算符
--（?、?|、?&）等操作，请使用默认的 jsonb_ops 运算符类。

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
-- 场景 8：为物理存储顺序与时间高度相关的超大表创建 BRIN 索引
-- ---------------------------------------------------------------------------
-- 数据按 created_at 顺序写入，因此每个页面范围的最小值和最大值跨度较小。
-- BRIN 索引体积很小，但属于有损索引：它先缩小堆页面范围，再逐行复查。如果堆表
-- 与 created_at 缺乏相关性，同样的 BRIN 索引可能不会产生明显效果。

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

-- 比较分阶段实验最终保留的索引。前面的大小查询已经记录了临时的单列索引、
-- 复合 B-tree 索引和覆盖 B-tree 索引。
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

-- 可选后续操作：脚本提交后单独执行以下语句，再重新运行场景 4，检查由可见性映射
-- 决定的堆获取次数：
-- VACUUM (ANALYZE) db_index_lab.orders;

-- 可选清理操作（默认不执行）：
-- DROP SCHEMA db_index_lab CASCADE;
