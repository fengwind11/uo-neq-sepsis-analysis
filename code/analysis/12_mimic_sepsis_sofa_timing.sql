\set ON_ERROR_STOP on
SET statement_timeout='300s';
BEGIN;
CREATE TEMP TABLE x(analysis_row bigint,stay_id int,t0 timestamp,weight_kg double precision,
                    urine_ml_6h double precision,uo_ml_kg_h double precision,hadm_id int);
\copy x FROM 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/PRIVATE_WORK/mimic_source_anchor.csv' CSV HEADER
CREATE INDEX ON x(stay_id);
CREATE TEMP TABLE timing AS
SELECT x.analysis_row,x.stay_id,x.t0,s.suspected_infection_time,s.sofa_time,s.sofa_score,
       extract(epoch FROM(s.suspected_infection_time-x.t0))/60 AS infection_min_from_t0,
       extract(epoch FROM(s.sofa_time-x.t0))/60 AS sofa_summary_min_from_t0,
       s.respiration,s.coagulation,s.liver,s.cardiovascular,s.cns,s.renal
FROM x JOIN mimiciv_derived.sepsis3 s USING(stay_id);
SELECT analysis_row,t0,suspected_infection_time,sofa_time,sofa_score,
       infection_min_from_t0,sofa_summary_min_from_t0
FROM timing ORDER BY analysis_row
\g (format=csv) 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/PRIVATE_WORK/mimic_sepsis_timing_by_case.csv'
SELECT count(*) ratio_cohort_n,count(*) FILTER(WHERE infection_min_from_t0<=0) infection_recorded_by_t0_n,
       count(*) FILTER(WHERE infection_min_from_t0>0) infection_after_t0_n,
       count(*) FILTER(WHERE sofa_summary_min_from_t0<=0) sofa_summary_by_t0_n,
       count(*) FILTER(WHERE sofa_summary_min_from_t0>0) sofa_summary_after_t0_n,
       percentile_cont(ARRAY[0.01,0.25,0.5,0.75,0.99]) WITHIN GROUP(ORDER BY infection_min_from_t0) infection_min_p01_p25_p50_p75_p99,
       percentile_cont(ARRAY[0.01,0.25,0.5,0.75,0.99]) WITHIN GROUP(ORDER BY sofa_summary_min_from_t0) sofa_min_p01_p25_p50_p75_p99
FROM timing
\g (format=csv) 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/CORRECTED_MANUSCRIPT_RESULTS_v1_1/01_SOURCE_LINEAGE/mimic_sepsis_timing_summary.csv'
CREATE TEMP TABLE sofa_component_hours AS
SELECT t.analysis_row,t.t0,v.component,v.score,
       min(sf.endtime) FILTER(WHERE v.raw_hour_score=v.score) AS earliest_possible_hour_end,
       max(sf.endtime) FILTER(WHERE v.raw_hour_score=v.score) AS latest_possible_hour_end,
       count(*) FILTER(WHERE v.raw_hour_score=v.score) AS matching_hour_n
FROM timing t
LEFT JOIN mimiciv_derived.sofa sf ON sf.stay_id=t.stay_id
  AND sf.endtime>t.sofa_time-interval '24 hour' AND sf.endtime<=t.sofa_time
CROSS JOIN LATERAL (VALUES
  ('respiration',t.respiration,sf.respiration),
  ('coagulation',t.coagulation,sf.coagulation),
  ('liver',t.liver,sf.liver),
  ('cardiovascular',t.cardiovascular,sf.cardiovascular),
  ('cns',t.cns,sf.cns),
  ('renal',t.renal,sf.renal)
) v(component,score,raw_hour_score)
GROUP BY t.analysis_row,t.t0,v.component,v.score;
SELECT * FROM sofa_component_hours ORDER BY analysis_row,component
\g (format=csv) 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/PRIVATE_WORK/mimic_sofa_component_possible_hours.csv'
SELECT component,count(*) n,count(*) FILTER(WHERE matching_hour_n>0) matched_hour_n,
       count(*) FILTER(WHERE earliest_possible_hour_end>t0) possible_hour_after_t0_n,
       min(earliest_possible_hour_end-t0) AS earliest_relative_interval,
       max(latest_possible_hour_end-t0) AS latest_relative_interval,
       'hourly score match; exact raw component measurement time UNVERIFIED'::text AS source_time_status
FROM sofa_component_hours GROUP BY component ORDER BY component
\g (format=csv) 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/CORRECTED_MANUSCRIPT_RESULTS_v1_1/01_SOURCE_LINEAGE/mimic_sofa_component_time_bounds.csv'
ROLLBACK;
