-- List of configuration the test suite is run against:
--SET spark.sql.autoBroadcastJoinThreshold=10485760
--SET spark.sql.autoBroadcastJoinThreshold=-1,spark.sql.join.preferSortMergeJoin=true
--SET spark.sql.autoBroadcastJoinThreshold=-1,spark.sql.join.preferSortMergeJoin=false

CREATE TEMPORARY VIEW t1 AS SELECT * FROM VALUES (1) AS GROUPING(a);
CREATE TEMPORARY VIEW t2 AS SELECT * FROM VALUES (1) AS GROUPING(a);
CREATE TEMPORARY VIEW t3 AS SELECT * FROM VALUES (1), (1) AS GROUPING(a);
CREATE TEMPORARY VIEW t4 AS SELECT * FROM VALUES (1), (1) AS GROUPING(a);

CREATE TEMPORARY VIEW ta AS
SELECT a, 'a' AS tag FROM t1
UNION ALL
SELECT a, 'b' AS tag FROM t2;

CREATE TEMPORARY VIEW tb AS
SELECT a, 'a' AS tag FROM t3
UNION ALL
SELECT a, 'b' AS tag FROM t4;

-- SPARK-19766 Constant alias columns in INNER JOIN should not be folded by FoldablePropagation rule
SELECT tb.* FROM ta INNER JOIN tb ON ta.a = tb.a AND ta.tag = tb.tag;
