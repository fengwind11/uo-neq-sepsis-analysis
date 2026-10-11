\set ON_ERROR_STOP on
SET statement_timeout='300s';
BEGIN;
CREATE TEMP TABLE a(
 analysis_row bigint, stay_id int, hospital_stay_id int, hospitalid int, t0 int,
 death28 double precision, weight_kg double precision, urine_ml_6h double precision,
 uo_ml_kg_h double precision, twa_neq double precision, scaled_uo_neq double precision,
 age double precision, female int, baseline_creatinine double precision, ckd_proxy int,
 lactate_pre_t0 double precision, map_pre_t0 double precision, vent_primary int, anuria int
);
\copy a FROM 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/PRIVATE_WORK/MANUSCRIPT_PREP_ANCHORS/eicu_anchor.csv' CSV HEADER
CREATE UNIQUE INDEX ON a(stay_id);
CREATE TEMP TABLE cr_trace AS
SELECT a.analysis_row,a.stay_id,a.t0,a.baseline_creatinine,
       lastlab.last_offset,lastlab.selected_labid,lastlab.last_value,
       lastlab.same_offset_n,lastlab.same_offset_distinct_values,
       abs(lastlab.last_value-a.baseline_creatinine)<0.000001 AS value_matches_extract,
       a.t0-lastlab.last_offset AS minutes_before_t0,
       CASE WHEN a.baseline_creatinine IS NULL THEN 'MISSING_PRE_T0_MEASUREMENT'
            WHEN lastlab.last_offset IS NULL THEN 'UNVERIFIED_NO_SOURCE_MATCH'
            WHEN abs(lastlab.last_value-a.baseline_creatinine)>=0.000001 THEN 'UNVERIFIED_VALUE_DISCORDANCE'
            WHEN lastlab.same_offset_distinct_values>1 THEN 'VERIFIED_TIE_BROKEN_BY_LABID'
            ELSE 'VERIFIED_LAST_PRE_T0_MEASUREMENT' END AS status
FROM a LEFT JOIN LATERAL (
  WITH eligible AS (
    SELECT l.labid,l.labresultoffset,l.labresult
    FROM eicu_crd.lab l
    WHERE l.patientunitstayid=a.stay_id
      AND lower(btrim(l.labname))='creatinine'
      AND lower(btrim(l.labmeasurenamesystem))='mg/dl'
      AND l.labresultoffset BETWEEN a.t0-1440 AND a.t0
      AND l.labresult>0 AND l.labresult<=150
  ), lastoff AS (SELECT max(labresultoffset) o FROM eligible)
  SELECT max(e.labresultoffset) last_offset,max(e.labid) selected_labid,
         (array_agg(e.labresult ORDER BY e.labid DESC))[1] last_value,
         count(*) same_offset_n,count(DISTINCT e.labresult) same_offset_distinct_values
  FROM eligible e JOIN lastoff lo ON e.labresultoffset=lo.o
) lastlab ON true;
\copy (SELECT * FROM cr_trace ORDER BY analysis_row) TO 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/PRIVATE_WORK/eicu_creatinine_source_by_case.csv' CSV HEADER
SELECT count(*) AS model_n,
       count(*) FILTER(WHERE baseline_creatinine IS NULL) AS missing_n,
       count(*) FILTER(WHERE status='VERIFIED_LAST_PRE_T0_MEASUREMENT') AS verified_n,
       count(*) FILTER(WHERE status='VERIFIED_TIE_BROKEN_BY_LABID') AS value_tie_n,
       count(*) FILTER(WHERE status LIKE 'UNVERIFIED%') AS unverified_n,
       min(minutes_before_t0) AS min_minutes_before_t0,max(minutes_before_t0) AS max_minutes_before_t0,
       percentile_cont(ARRAY[.01,.25,.5,.75,.99]) WITHIN GROUP(ORDER BY minutes_before_t0) AS minutes_before_t0_p01_p25_p50_p75_p99
FROM cr_trace
\g (format=csv) 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/CORRECTED_MANUSCRIPT_RESULTS_v1_1/01_SOURCE_LINEAGE/eicu_creatinine_source_summary.csv'
ROLLBACK;
