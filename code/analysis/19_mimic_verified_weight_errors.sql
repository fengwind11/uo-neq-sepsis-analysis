\set ON_ERROR_STOP on
SET statement_timeout='300s';
BEGIN;
CREATE TEMP TABLE a(stay_id int,t0 timestamp,legacy_weight double precision,legacy_uo_ml_kg_h double precision);
\copy a FROM 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/PRIVATE_WORK/legacy_weight_error_anchor.csv' CSV HEADER
CREATE UNIQUE INDEX ON a(stay_id);
CREATE TEMP TABLE weight_trace AS
SELECT a.stay_id,a.t0,a.legacy_weight,a.legacy_uo_ml_kg_h,
       c.charttime,c.itemid,di.label,c.valuenum,c.valueuom,
       wd.starttime,wd.endtime,wd.weight AS active_derived_weight,wd.weight_type
FROM a JOIN mimiciv_icu.chartevents c ON c.stay_id=a.stay_id
 AND c.itemid IN (226512,224639)
LEFT JOIN mimiciv_icu.d_items di ON di.itemid=c.itemid
LEFT JOIN mimiciv_derived.weight_durations wd ON wd.stay_id=a.stay_id
 AND wd.starttime<=a.t0 AND wd.endtime>a.t0;
\copy (SELECT * FROM weight_trace ORDER BY stay_id,charttime) TO 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/PRIVATE_WORK/legacy_weight_error_source_rows.csv' CSV HEADER
SELECT a.legacy_weight AS recorded_weight_kg,count(DISTINCT a.stay_id) cases,
       count(t.charttime) source_weight_chart_rows,
       count(t.charttime) FILTER(WHERE t.charttime<=a.t0 AND t.valuenum>0 AND t.valuenum NOT IN (1,2)) pre_t0_alternate_nonerror_weight_rows,
       min(a.legacy_uo_ml_kg_h) old_uo_min,max(a.legacy_uo_ml_kg_h) old_uo_max,
       'SOURCE_CHARTED_1_OR_2_KG_ADULT_NO_PRE_T0_ALTERNATE; SET_WEIGHT_MISSING' AS status
FROM a LEFT JOIN weight_trace t ON t.stay_id=a.stay_id
GROUP BY a.legacy_weight ORDER BY a.legacy_weight
\g (format=csv) 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/CORRECTED_MANUSCRIPT_RESULTS_v1_1/01_SOURCE_LINEAGE/mimic_verified_weight_errors.csv'
ROLLBACK;
