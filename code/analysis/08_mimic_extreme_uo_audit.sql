\set ON_ERROR_STOP on
SET statement_timeout='300s';
BEGIN;
CREATE TEMP TABLE x(analysis_row bigint,stay_id int,t0 timestamp,weight_kg double precision,
                    urine_ml_6h double precision,uo_ml_kg_h double precision,hadm_id int);
\copy x FROM 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/PRIVATE_WORK/mimic_extreme_anchor.csv' CSV HEADER
CREATE TEMP TABLE raw AS
SELECT x.analysis_row,x.stay_id,x.t0,x.weight_kg,x.urine_ml_6h,x.uo_ml_kg_h,
       oe.charttime,oe.itemid,d.label,oe.value,oe.valueuom,
       CASE WHEN oe.itemid=227488 AND oe.value>0 THEN -oe.value ELSE oe.value END AS concept_contribution_ml,
       count(*) OVER(PARTITION BY x.stay_id,oe.charttime) AS raw_rows_same_time
FROM x JOIN mimiciv_icu.outputevents oe ON oe.stay_id=x.stay_id
  AND oe.charttime>x.t0 AND oe.charttime<=x.t0+interval '6 hour'
JOIN mimiciv_icu.d_items d ON d.itemid=oe.itemid
WHERE oe.itemid IN (226559,226560,226561,226584,226563,226564,226565,
                    226567,226557,226558,227488,227489);
SELECT * FROM raw ORDER BY analysis_row,charttime,itemid
\g (format=csv) 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/PRIVATE_WORK/mimic_extreme_uo_raw_30.csv'
SELECT analysis_row,weight_kg,urine_ml_6h,uo_ml_kg_h,count(*) AS source_rows,
       count(DISTINCT charttime) AS source_times,
       sum(concept_contribution_ml) AS source_recomputed_ml,
       sum(concept_contribution_ml) FILTER(WHERE itemid IN (227488,227489)) AS irrigation_net_ml,
       count(*) FILTER(WHERE raw_rows_same_time>1) AS rows_at_duplicate_times,
       min(valueuom) AS min_unit,max(valueuom) AS max_unit
FROM raw GROUP BY 1,2,3,4 ORDER BY uo_ml_kg_h DESC
\g (format=csv) 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/CORRECTED_MANUSCRIPT_RESULTS_v1_1/01_SOURCE_LINEAGE/mimic_extreme_uo_source_summary.csv'
ROLLBACK;
