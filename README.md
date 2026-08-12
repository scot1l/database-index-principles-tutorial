# 数据库索引原理：慢 SQL 侦探手册

一份面向前后端开发者的中文长页面技术分享材料，以订单列表慢接口为主线，讲清数据库索引原理、执行计划和接口性能优化方法。

![教程首屏预览](assets/preview.png)

## 直接阅读

双击打开 `index.html` 即可。页面完全离线运行，无需安装依赖或启动构建工具；支持桌面端、移动端、键盘操作和打印为 PDF。

页面包含：

- PostgreSQL 14+ 为主、MySQL 8.x / InnoDB 对照
- 页、B-tree/B+Tree 心智模型、选择性、回表与 MVCC
- 联合、覆盖、部分、表达式、GIN、GiST、SP-GiST、BRIN、Hash 索引
- 4 个核心交互实验和 1 个索引类型问诊工具
- 深分页、可选筛选、任意排序、N+1 等前后端协作问题
- 慢接口排查流程、迷思小测和可打印速查表
- PostgreSQL 与 MySQL 可运行实验脚本

## PostgreSQL 实验

脚本默认生成 100 万条订单数据，需要 `psql`：

```powershell
psql -d your_database -f labs/postgresql.sql
```

快速体验可缩小数据规模：

```powershell
psql -d your_database -v order_count=250000 -f labs/postgresql.sql
```

脚本会删除并重建专用 schema `db_index_lab`。请只在本地或一次性数据库中运行，并先阅读脚本顶部说明。

## MySQL 对照实验

```powershell
mysql --table --execute="SOURCE labs/mysql.sql"
```

`EXPLAIN ANALYZE` 需要 MySQL 8.0.18 或更新版本。脚本会在专用 database `db_index_lab` 中重建实验表，不面向 MariaDB。

两份脚本围绕同一套订单字段展开：`id`、`tenant_id`、`user_id`、`status`、`total_cents`、`created_at`、`updated_at`、`deleted_at`、`metadata`。状态值统一为大写的 `NEW/PAID/SHIPPED/CANCELLED/REFUNDED`，便于在教程与实验之间直接对照。

## 文件结构

```text
.
├── index.html
├── ACCEPTANCE.md
├── README.md
├── assets
│   └── preview.png
└── labs
    ├── postgresql.sql
    └── mysql.sql
```

所有示例耗时、成本和页访问图均用于教学，不构成固定性能承诺。真实结论应来自目标版本、代表性数据和实际执行计划。

## 验收记录

完整的桌面、移动端、键盘、交互、打印与内容准确性验收证据记录在 `ACCEPTANCE.md`。页面运行时验收使用 Codex 内置浏览器；打印版另生成 PDF 并逐页渲染检查。
