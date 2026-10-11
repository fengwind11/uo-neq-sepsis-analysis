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

WITH old_nurse AS (
  SELECT n.nursingchartcelltypevallabel AS label,n.nursingchartcelltypevalname AS child,
         CASE WHEN btrim(n.nursingchartvalue) LIKE '%/%' THEN 'SLASH' ELSE 'NUMERIC' END AS value_format,
         count(*) AS record_n
  FROM a JOIN eicu_crd.nursecharting n ON n.patientunitstayid=a.stay_id
    AND n.nursingchartoffset BETWEEN a.t0-360 AND a.t0
  WHERE lower(n.nursingchartcelltypevallabel) IN ('non-invasive bp','invasive bp')
    AND split_part(btrim(n.nursingchartvalue),'/',1) ~ '^[0-9]+([.][0-9]+)?$'
    AND split_part(n.nursingchartvalue,'/',1)::double precision BETWEEN 40 AND 300
  GROUP BY 1,2,3
), new_nurse AS (
  SELECT n.nursingchartcelltypevallabel AS label,n.nursingchartcelltypevalname AS child,
         count(*) AS record_n
  FROM a JOIN eicu_crd.nursecharting n ON n.patientunitstayid=a.stay_id
    AND n.nursingchartoffset BETWEEN a.t0-360 AND a.t0
  WHERE lower(n.nursingchartcelltypevalname) IN ('invasive bp systolic','non-invasive bp systolic')
    AND btrim(n.nursingchartvalue) ~ '^[0-9]+([.][0-9]+)?$'
    AND n.nursingchartvalue::double precision BETWEEN 40 AND 300
  GROUP BY 1,2
)
SELECT cohort_n,rule,label,child,value_format,record_n FROM (
  SELECT 1803 AS cohort_n,'OLD_ACCEPTED_NURSE'::text AS rule,label,child,value_format,record_n FROM old_nurse
  UNION ALL SELECT 1803,'NEW_ELIGIBLE_SYSTOLIC_CHILD',label,child,'NUMERIC',record_n FROM new_nurse
  UNION ALL SELECT 1803,'OLD_AND_NEW_VITALPERIODIC','vitalPeriodic','systemicsystolic','NUMERIC',count(*)
  FROM a JOIN eicu_crd.vitalperiodic v ON v.patientunitstayid=a.stay_id
    AND v.observationoffset BETWEEN a.t0-360 AND a.t0 WHERE v.systemicsystolic BETWEEN 40 AND 300
) q ORDER BY rule,label,child,value_format
\g (format=csv) 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/CORRECTED_MANUSCRIPT_RESULTS_v1_1/01_SOURCE_LINEAGE/eicu_sbp_record_flow.csv'
ROLLBACK;
