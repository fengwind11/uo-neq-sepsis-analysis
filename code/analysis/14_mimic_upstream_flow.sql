\set ON_ERROR_STOP on
SET statement_timeout='300s';
BEGIN;
CREATE TEMP TABLE neq_work ON COMMIT DROP AS
SELECT stay_id,starttime,endtime,norepinephrine_equivalent_dose
FROM mimiciv_derived.norepinephrine_equivalent_dose
WHERE norepinephrine_equivalent_dose>0 AND endtime>starttime;
CREATE INDEX ON neq_work(stay_id,starttime,endtime);
ANALYZE neq_work;

CREATE TEMP TABLE flow_base ON COMMIT DROP AS
WITH ordered_neq AS (
  SELECT *,max(endtime) OVER(PARTITION BY stay_id ORDER BY starttime,endtime
                            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) prior_max_end
  FROM neq_work
), marked AS (
  SELECT *,CASE WHEN prior_max_end IS NULL OR starttime>prior_max_end+interval '5 min'
                THEN 1 ELSE 0 END new_island
  FROM ordered_neq
), grouped AS (
  SELECT *,sum(new_island) OVER(PARTITION BY stay_id ORDER BY starttime,endtime) island_id
  FROM marked
), sustained AS (
  SELECT stay_id,island_id,min(starttime) t0,max(endtime) island_end
  FROM grouped GROUP BY stay_id,island_id
  HAVING max(endtime)-min(starttime)>=interval '60 min'
), first_stay_t0 AS (
  SELECT stay_id,min(t0) t0 FROM sustained GROUP BY stay_id
), eligible AS (
  SELECT d.stay_id,d.subject_id,d.hadm_id,d.icu_intime,d.icu_outtime,d.dod,
         f.t0,a.deathtime,
         row_number() OVER(PARTITION BY d.subject_id ORDER BY f.t0,d.stay_id) rn
  FROM first_stay_t0 f JOIN mimiciv_derived.icustay_detail d USING(stay_id)
  JOIN mimiciv_derived.sepsis3 s USING(stay_id)
  JOIN mimiciv_hosp.admissions a USING(hadm_id)
  WHERE d.admission_age>=18 AND s.sepsis3
)
SELECT *,
       (t0>=icu_intime) t0_inside_icu,
       (deathtime IS NULL OR deathtime>t0+interval '6 hour') survived_6h,
       (icu_outtime>=t0+interval '6 hour') observed_6h,
       (dod IS NOT NULL AND dod<=(t0+interval '28 day')::date) death28
FROM eligible;

WITH adult AS (
  SELECT d.stay_id FROM mimiciv_derived.icustay_detail d WHERE d.admission_age>=18
), adult_sepsis AS (
  SELECT d.stay_id FROM adult d JOIN mimiciv_derived.sepsis3 s USING(stay_id) WHERE s.sepsis3
), adult_pressor AS (
  SELECT DISTINCT s.stay_id FROM adult_sepsis s JOIN neq_work n USING(stay_id)
), first_person AS (
  SELECT * FROM flow_base WHERE rn=1
), in_icu AS (
  SELECT * FROM first_person WHERE t0_inside_icu
), alive AS (
  SELECT * FROM in_icu WHERE survived_6h
), observed AS (
  SELECT * FROM alive WHERE observed_6h
)
SELECT step,criterion,n,deaths,step_type FROM (
  SELECT 0 step,'adult ICU stay' criterion,count(*) n,NULL::bigint deaths,'sequential_stay_level' step_type FROM adult
  UNION ALL SELECT 1,'adult stay with sepsis3 anywhere in stay',count(*),NULL::bigint,'sequential_stay_level' FROM adult_sepsis
  UNION ALL SELECT 2,'adult sepsis stay with any positive convertible NEE record',count(*),NULL::bigint,'sequential_stay_level' FROM adult_pressor
  UNION ALL SELECT 3,'adult sepsis stay with first sustained 60-min NEE island',count(*),NULL::bigint,'sequential_stay_level' FROM flow_base
  UNION ALL SELECT 4,'first eligible stay per subject',count(*),sum(death28::int),'sequential_person_level' FROM first_person
  UNION ALL SELECT 5,'T0 within ICU stay',count(*),sum(death28::int),'sequential_person_level' FROM in_icu
  UNION ALL SELECT 6,'survived beyond T0+6h',count(*),sum(death28::int),'sequential_person_level' FROM alive
  UNION ALL SELECT 7,'ICU observed through T0+6h landmark',count(*),sum(death28::int),'sequential_person_level' FROM observed
  UNION ALL SELECT 8,'early death at or before T0+6h among in-ICU T0',count(*),count(*),'parallel_exclusion_from_step_5' FROM in_icu WHERE NOT survived_6h
  UNION ALL SELECT 9,'ICU out before T0+6h among 6h survivors',count(*),sum(death28::int),'parallel_exclusion_from_step_6' FROM alive WHERE NOT observed_6h
) q ORDER BY step
\g (format=csv) 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/CORRECTED_MANUSCRIPT_RESULTS_v1_1/01_SOURCE_LINEAGE/mimic_upstream_flow_source.csv'
ROLLBACK;
