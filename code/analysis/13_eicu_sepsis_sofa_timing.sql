\set ON_ERROR_STOP on
SET statement_timeout='300s';
BEGIN;
CREATE TEMP TABLE x(analysis_row bigint,stay_id int,t0 int,weight_kg double precision,
                    urine_ml_6h double precision,uo_ml_kg_h double precision);
\copy x FROM 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/PRIVATE_WORK/eicu_source_anchor.csv' CSV HEADER
CREATE TEMP TABLE timing AS
SELECT x.analysis_row,x.stay_id,x.t0,s.infection_evidence_offset,s.sepsis_sofa,
       s.infection_evidence_offset-x.t0 AS infection_min_from_t0,
       s.sofa_resp,s.sofa_coag,s.sofa_liver,s.sofa_cardio,s.sofa_cns,s.sofa_renal
FROM x JOIN research_vasopressor_restart_eicu_v1.e05_sepsis_cohort s ON s.patientunitstayid=x.stay_id;
SELECT analysis_row,t0,infection_evidence_offset,sepsis_sofa,infection_min_from_t0
FROM timing ORDER BY analysis_row
\g (format=csv) 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/PRIVATE_WORK/eicu_sepsis_timing_by_case.csv'
SELECT count(*) ratio_cohort_n,count(*) FILTER(WHERE infection_min_from_t0<=0) infection_recorded_by_t0_n,
       count(*) FILTER(WHERE infection_min_from_t0>0) infection_after_t0_n,
       percentile_cont(ARRAY[0.01,0.25,0.5,0.75,0.99]) WITHIN GROUP(ORDER BY infection_min_from_t0) infection_min_p01_p25_p50_p75_p99,
       'e05 creation SQL and SOFA component source timestamps not located; timing UNRESOLVED'::text AS status
FROM timing
\g (format=csv) 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/CORRECTED_MANUSCRIPT_RESULTS_v1_1/01_SOURCE_LINEAGE/eicu_sepsis_timing_summary.csv'
SELECT v.component,count(*) n,
       NULL::int AS earliest_source_min_from_t0,NULL::int AS latest_source_min_from_t0,
       'UNRESOLVED_E05_CREATION_SQL_NOT_LOCATED'::text AS source_time_status
FROM timing t CROSS JOIN LATERAL (VALUES
  ('respiration',t.sofa_resp),('coagulation',t.sofa_coag),('liver',t.sofa_liver),
  ('cardiovascular',t.sofa_cardio),('cns',t.sofa_cns),('renal',t.sofa_renal)
) v(component,score)
GROUP BY v.component ORDER BY v.component
\g (format=csv) 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/CORRECTED_MANUSCRIPT_RESULTS_v1_1/01_SOURCE_LINEAGE/eicu_sofa_component_time_bounds.csv'
ROLLBACK;
