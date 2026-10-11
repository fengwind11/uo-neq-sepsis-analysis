\set ON_ERROR_STOP on
SET statement_timeout='900s';
BEGIN;
SET TRANSACTION READ ONLY;
SELECT nursingchartcelltypevallabel AS celltypevallabel,
       nursingchartcelltypevalname AS celltypevalname,
       CASE
         WHEN btrim(nursingchartvalue) ~ '^[0-9]+([.][0-9]+)?$' THEN 'NUMERIC'
         WHEN btrim(nursingchartvalue) ~ '^[0-9]+([.][0-9]+)?/[0-9]+([.][0-9]+)?$' THEN 'SBP_DBP_SLASH'
         ELSE 'OTHER'
       END AS value_format,
       count(*) AS record_n,
       min(nursingchartvalue) AS lexical_example
FROM eicu_crd.nursecharting
WHERE lower(nursingchartcelltypevallabel) IN ('non-invasive bp','invasive bp')
GROUP BY 1,2,3
ORDER BY 1,2,3
\g (format=csv) 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/CORRECTED_MANUSCRIPT_RESULTS_v1_1/01_SOURCE_LINEAGE/eicu_bp_label_name_format_full_frequency.csv'
ROLLBACK;
