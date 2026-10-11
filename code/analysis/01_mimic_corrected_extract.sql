\set ON_ERROR_STOP on
\pset pager off
SET statement_timeout='300s';
BEGIN;

-- Session-only working copies/indexes: source tables are never modified.
CREATE TEMP TABLE neq_work ON COMMIT DROP AS
SELECT stay_id,starttime,endtime,norepinephrine_equivalent_dose
FROM mimiciv_derived.norepinephrine_equivalent_dose
WHERE norepinephrine_equivalent_dose>0 AND endtime>starttime;
CREATE INDEX ON neq_work(stay_id,starttime,endtime);
ANALYZE neq_work;

CREATE TEMP TABLE rrt_active ON COMMIT DROP AS
SELECT stay_id,charttime FROM mimiciv_derived.rrt WHERE dialysis_active=1;
CREATE INDEX ON rrt_active(stay_id,charttime);
ANALYZE rrt_active;

CREATE TEMP TABLE chronic_hadm ON COMMIT DROP AS
SELECT DISTINCT hadm_id
FROM mimiciv_hosp.diagnoses_icd
WHERE (icd_version=9 AND icd_code IN ('5856','V451','V4511'))
   OR (icd_version=10 AND icd_code IN ('N186','Z992'));
CREATE INDEX ON chronic_hadm(hadm_id);

CREATE TEMP TABLE loop_emar ON COMMIT DROP AS
SELECT hadm_id,charttime
FROM mimiciv_hosp.emar
WHERE lower(medication) IN ('furosemide','lasix','bumetanide','bumex','torsemide','demadex')
  AND event_txt IN
 ('Administered','Delayed Administered','Administered in Other Location',
  'Partial Administered','Administered Bolus from IV Drip');
CREATE INDEX ON loop_emar(hadm_id,charttime);
ANALYZE loop_emar;

CREATE TEMP TABLE loop_iv ON COMMIT DROP AS
SELECT stay_id,starttime,endtime
FROM mimiciv_icu.inputevents
WHERE itemid IN (221794,228340,229639)
  AND coalesce(statusdescription,'')<>'Rewritten';
CREATE INDEX ON loop_iv(stay_id,starttime,endtime);
ANALYZE loop_iv;

CREATE TEMP TABLE candidate ON COMMIT DROP AS
WITH ordered_neq AS (
  SELECT *,
    max(endtime) OVER
      (PARTITION BY stay_id ORDER BY starttime,endtime
       ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS prior_max_end
  FROM neq_work
), marked AS (
  SELECT *,CASE WHEN prior_max_end IS NULL
                     OR starttime>prior_max_end+interval '5 min'
                THEN 1 ELSE 0 END AS new_island
  FROM ordered_neq
), grouped AS (
  SELECT *,sum(new_island) OVER
    (PARTITION BY stay_id ORDER BY starttime,endtime) AS island_id
  FROM marked
), sustained AS (
  SELECT stay_id,island_id,min(starttime) AS t0,max(endtime) AS island_end
  FROM grouped
  GROUP BY stay_id,island_id
  HAVING max(endtime)-min(starttime)>=interval '60 min'
), first_stay_t0 AS (
  SELECT stay_id,min(t0) AS t0 FROM sustained GROUP BY stay_id
), eligible AS (
  SELECT d.*,f.t0,a.deathtime,
    row_number() OVER(PARTITION BY d.subject_id ORDER BY f.t0,d.stay_id) AS rn
  FROM first_stay_t0 f
  JOIN mimiciv_derived.icustay_detail d USING(stay_id)
  JOIN mimiciv_derived.sepsis3 s USING(stay_id)
  JOIN mimiciv_hosp.admissions a USING(hadm_id)
  WHERE d.admission_age>=18 AND s.sepsis3
), landmark AS (
  SELECT * FROM eligible
  WHERE rn=1
    AND t0>=icu_intime
    AND icu_outtime>=t0+interval '6 hour'
    AND (deathtime IS NULL OR deathtime>t0+interval '6 hour')
)
SELECT b.*,w.weight,u.uo_6h,u.uo_rows,u.uo_distinct_times,n.twa_neq,
       (b.dod IS NOT NULL AND b.dod<=(b.t0+interval '28 day')::date) AS death28,
       ch.hadm_id IS NOT NULL AS chronic_dialysis,
       EXISTS(SELECT 1 FROM rrt_active r
              WHERE r.stay_id=b.stay_id
                AND r.charttime>=b.icu_intime AND r.charttime<b.t0) AS krt_pre_t0,
       EXISTS(SELECT 1 FROM rrt_active r
              WHERE r.stay_id=b.stay_id
                AND r.charttime>=b.t0 AND r.charttime<b.t0+interval '6 hour') AS krt_0_6,
       EXISTS(SELECT 1 FROM rrt_active r
              WHERE r.stay_id=b.stay_id
                AND r.charttime>=b.t0+interval '6 hour'
                AND r.charttime<b.t0+interval '24 hour') AS krt_6_24
FROM landmark b
LEFT JOIN chronic_hadm ch USING(hadm_id)
LEFT JOIN LATERAL (
  SELECT weight
  FROM mimiciv_derived.weight_durations wd
  WHERE wd.stay_id=b.stay_id
    AND wd.starttime<=b.t0 AND wd.endtime>b.t0 AND wd.weight>0
    AND wd.weight NOT IN (1,2) -- two adults had only source-charted 1/2 kg weights; no replacement exists
  ORDER BY wd.starttime DESC LIMIT 1
) w ON true
LEFT JOIN LATERAL (
  SELECT sum(urineoutput) AS uo_6h,
         count(*) AS uo_rows,
         count(DISTINCT charttime) AS uo_distinct_times
  FROM mimiciv_derived.urine_output uo
  WHERE uo.stay_id=b.stay_id
    AND uo.charttime>b.t0 AND uo.charttime<=b.t0+interval '6 hour'
) u ON true
LEFT JOIN LATERAL (
  SELECT sum(x.norepinephrine_equivalent_dose
             * extract(epoch FROM
               (least(x.endtime,b.t0+interval '6 hour')-greatest(x.starttime,b.t0))))/21600.0
         AS twa_neq
  FROM neq_work x
  WHERE x.stay_id=b.stay_id
    AND x.endtime>b.t0 AND x.starttime<b.t0+interval '6 hour'
) n ON true;
CREATE INDEX ON candidate(stay_id);
ANALYZE candidate;

CREATE TEMP TABLE exposure_flags ON COMMIT DROP AS
SELECT c.stay_id,
  EXISTS(SELECT 1 FROM loop_emar e
         WHERE e.hadm_id=c.hadm_id
           AND e.charttime>=c.t0-interval '6 hour' AND e.charttime<c.t0)
  OR EXISTS(SELECT 1 FROM loop_iv i
            WHERE i.stay_id=c.stay_id
              AND i.endtime>c.t0-interval '6 hour' AND i.starttime<c.t0) AS loop_pre6,
  EXISTS(SELECT 1 FROM loop_emar e
         WHERE e.hadm_id=c.hadm_id
           AND e.charttime>=c.t0 AND e.charttime<c.t0+interval '6 hour')
  OR EXISTS(SELECT 1 FROM loop_iv i
            WHERE i.stay_id=c.stay_id
              AND i.endtime>c.t0 AND i.starttime<c.t0+interval '6 hour') AS loop_0_6,
  EXISTS(SELECT 1 FROM loop_emar e
         WHERE e.hadm_id=c.hadm_id
           AND e.charttime>=c.t0+interval '6 hour'
           AND e.charttime<c.t0+interval '24 hour')
  OR EXISTS(SELECT 1 FROM loop_iv i
            WHERE i.stay_id=c.stay_id
              AND i.endtime>c.t0+interval '6 hour'
              AND i.starttime<c.t0+interval '24 hour') AS loop_6_24
FROM candidate c;

CREATE TEMP TABLE mimic_cohort_flow ON COMMIT DROP AS
SELECT 'landmark_base' AS metric,count(*) AS n,
       count(*) FILTER(WHERE death28) AS deaths FROM candidate
UNION ALL SELECT 'weight_available',count(*) FILTER(WHERE weight IS NOT NULL),
       count(*) FILTER(WHERE death28 AND weight IS NOT NULL) FROM candidate
UNION ALL SELECT 'uo_available',count(*) FILTER(WHERE uo_rows>0),
       count(*) FILTER(WHERE death28 AND uo_rows>0) FROM candidate
UNION ALL SELECT 'neq_available',count(*) FILTER(WHERE twa_neq>0),
       count(*) FILTER(WHERE death28 AND twa_neq>0) FROM candidate
UNION ALL SELECT 'ratio_valid_nonnegative_uo',
       count(*) FILTER(WHERE weight>0 AND uo_rows>0 AND uo_6h>=0 AND twa_neq>0),
       count(*) FILTER(WHERE death28 AND weight>0 AND uo_rows>0 AND uo_6h>=0 AND twa_neq>0)
       FROM candidate
UNION ALL SELECT 'clean_ratio',
       count(*) FILTER(WHERE weight>0 AND uo_rows>0 AND uo_6h>=0 AND twa_neq>0
         AND NOT chronic_dialysis AND NOT krt_pre_t0 AND NOT krt_0_6 AND NOT loop_0_6),
       count(*) FILTER(WHERE death28 AND weight>0 AND uo_rows>0 AND uo_6h>=0 AND twa_neq>0
         AND NOT chronic_dialysis AND NOT krt_pre_t0 AND NOT krt_0_6 AND NOT loop_0_6)
       FROM candidate JOIN exposure_flags USING(stay_id);

SELECT count(*) AS n,
 count(*) FILTER(WHERE chronic_dialysis) AS chronic_dialysis,
 count(*) FILTER(WHERE krt_pre_t0) AS krt_pre_t0,
 count(*) FILTER(WHERE krt_0_6) AS krt_0_6,
 count(*) FILTER(WHERE krt_6_24) AS krt_6_24,
 count(*) FILTER(WHERE loop_pre6) AS loop_pre6,
 count(*) FILTER(WHERE loop_0_6) AS loop_0_6,
 count(*) FILTER(WHERE loop_6_24) AS loop_6_24,
 count(*) FILTER(WHERE uo_rows=1) AS single_uo_row,
 count(*) FILTER(WHERE uo_distinct_times=1) AS single_uo_time,
 count(*) FILTER(WHERE uo_6h<0) AS negative_uo_total,
 count(*) FILTER(WHERE twa_neq<0.02) AS twa_lt_002
FROM candidate JOIN exposure_flags USING(stay_id);

SELECT
 percentile_cont(ARRAY[0,0.01,0.05,0.1,0.25,0.5,0.75,0.9,0.95,0.99,1])
   WITHIN GROUP(ORDER BY uo_6h/(weight*6.0)) AS uo_mlkg_h_quantiles,
 percentile_cont(ARRAY[0,0.01,0.05,0.1,0.25,0.5,0.75,0.9,0.95,0.99,1])
   WITHIN GROUP(ORDER BY twa_neq) AS twa_neq_quantiles,
 percentile_cont(ARRAY[0,0.01,0.05,0.5,0.95,0.99,1])
   WITHIN GROUP(ORDER BY weight) AS weight_quantiles
FROM candidate
WHERE weight>0 AND uo_rows>0 AND uo_6h>=0 AND twa_neq>0;

CREATE TEMP TABLE neq_clip ON COMMIT DROP AS
SELECT c.stay_id,
       greatest(n.starttime,c.t0) AS seg_start,
       least(n.endtime,c.t0+interval '6 hour') AS seg_end
FROM candidate c
JOIN neq_work n ON n.stay_id=c.stay_id
  AND n.endtime>c.t0 AND n.starttime<c.t0+interval '6 hour';

CREATE TEMP TABLE neq_active ON COMMIT DROP AS
WITH o AS (
  SELECT *, max(seg_end) OVER (
    PARTITION BY stay_id ORDER BY seg_start,seg_end
    ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS prior_end
  FROM neq_clip
), m AS (
  SELECT *, CASE WHEN prior_end IS NULL OR seg_start>prior_end THEN 1 ELSE 0 END AS brk
  FROM o
), g AS (
  SELECT *, sum(brk) OVER (PARTITION BY stay_id ORDER BY seg_start,seg_end) AS grp
  FROM m
), e AS (
  SELECT stay_id,grp,min(seg_start) AS ep_start,max(seg_end) AS ep_end
  FROM g GROUP BY stay_id,grp
)
SELECT stay_id,
       sum(extract(epoch FROM (ep_end-ep_start))/60.0) AS active_minutes
FROM e GROUP BY stay_id;
CREATE UNIQUE INDEX ON neq_active(stay_id);

CREATE TEMP TABLE mimic_ratio_analysis ON COMMIT DROP AS
SELECT row_number() OVER (ORDER BY c.stay_id) AS analysis_row,
       c.stay_id AS local_stay_id,c.hadm_id AS local_hadm_id,c.subject_id AS local_subject_id,
       c.t0,c.icu_intime,c.icu_outtime,
       c.death28::int AS death28,
       CASE WHEN c.hospital_expire_flag=1 AND c.deathtime>c.t0+interval '6 hour' AND c.deathtime<=c.t0+interval '28 day' THEN 1 ELSE 0 END AS death28_inhospital,
       c.weight::double precision AS weight_kg,c.uo_6h::double precision AS urine_ml_6h,
       (c.uo_6h/(c.weight*6.0))::double precision AS uo_ml_kg_h,
       c.twa_neq::double precision AS twa_neq,
       (0.1*(c.uo_6h/(c.weight*6.0))/c.twa_neq)::double precision AS scaled_uo_neq,
       (a.active_minutes/360.0)::double precision AS active_prop,
       (NOT c.chronic_dialysis AND NOT c.krt_pre_t0 AND NOT c.krt_0_6 AND NOT f.loop_0_6) AS clean_cohort,
       c.chronic_dialysis, c.krt_pre_t0, c.krt_0_6,
       f.loop_pre6, f.loop_0_6, f.loop_6_24,
       c.admission_age::double precision AS age,
       (upper(c.gender)='F')::int AS female,
       cr.valuenum::double precision AS baseline_creatinine,
       cr.charttime AS creatinine_source_time,
       cr.labevent_id AS creatinine_source_id,
       extract(epoch FROM (c.t0-cr.charttime))/60.0 AS creatinine_minutes_before_t0,
       cb.scr_baseline::double precision AS legacy_scr_baseline,
       cb.scr_min::double precision AS legacy_scr_min,
       cb.mdrd_est::double precision AS legacy_mdrd_est,
       CASE WHEN cb.scr_min<=1.1 OR cb.ckd=1 THEN 'ADMISSION_WIDE_MINIMUM'
            WHEN cb.scr_baseline IS NOT NULL THEN 'MDRD_ESTIMATE'
            ELSE 'MISSING' END AS legacy_creatinine_source_type,
       minlab.first_time AS legacy_min_first_source_time,
       minlab.last_time AS legacy_min_last_source_time,
       CASE WHEN cb.scr_min<=1.1 OR cb.ckd=1
            THEN CASE WHEN minlab.first_time IS NULL THEN 'UNVERIFIED'
                      WHEN minlab.last_time>c.t0 THEN 'HAS_POST_T0_MATCH'
                      ELSE 'MATCHES_PRE_T0_BUT_ALGORITHM_USES_FULL_ADMISSION' END
            WHEN cb.scr_baseline IS NOT NULL THEN 'NON_MEASURED_MDRD'
            ELSE 'MISSING' END AS legacy_creatinine_time_status,
       coalesce(cb.ckd,0)::int AS ckd_proxy,
       CASE WHEN s.sofa_time<=c.t0 THEN s.sofa_score END::double precision AS pre_t0_sepsis_sofa,
       lac.lactate::double precision AS lactate_pre_t0,
       mp.map_pre_t0::double precision AS map_pre_t0,
       EXISTS(
         SELECT 1 FROM mimiciv_derived.ventilation vv
         WHERE vv.stay_id=c.stay_id
           AND vv.starttime<=c.t0 AND vv.endtime>c.t0
           AND vv.ventilation_status IN ('InvasiveVent','Tracheostomy')
       )::int AS invasive_vent_t0,
       c.uo_rows, c.uo_distinct_times
FROM candidate c
JOIN exposure_flags f USING(stay_id)
JOIN neq_active a USING(stay_id)
LEFT JOIN mimiciv_derived.creatinine_baseline cb USING(hadm_id)
LEFT JOIN LATERAL (
  SELECT l.labevent_id,l.charttime,l.valuenum
  FROM mimiciv_hosp.labevents l
  WHERE l.hadm_id=c.hadm_id AND l.itemid=50912 AND l.valueuom='mg/dL'
    AND l.charttime>=c.t0-interval '24 hour' AND l.charttime<=c.t0
    AND l.valuenum>0 AND l.valuenum<=150
  ORDER BY l.charttime DESC,l.labevent_id DESC LIMIT 1
) cr ON true
LEFT JOIN LATERAL (
  SELECT min(l.charttime) AS first_time,max(l.charttime) AS last_time
  FROM mimiciv_hosp.labevents l
  WHERE l.hadm_id=c.hadm_id AND l.itemid=50912 AND l.valueuom='mg/dL'
    AND abs(l.valuenum-cb.scr_min)<0.000001
) minlab ON true
LEFT JOIN mimiciv_derived.sepsis3 s USING(stay_id)
LEFT JOIN LATERAL (
  SELECT b.lactate
  FROM mimiciv_derived.bg b
  WHERE b.hadm_id=c.hadm_id AND b.lactate IS NOT NULL
    AND b.charttime>=c.t0-interval '6 hour' AND b.charttime<=c.t0
  ORDER BY b.charttime DESC LIMIT 1
) lac ON true
LEFT JOIN LATERAL (
  SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY v.mbp) AS map_pre_t0
  FROM mimiciv_derived.vitalsign v
  WHERE v.stay_id=c.stay_id AND v.mbp BETWEEN 20 AND 200
    AND v.charttime>=c.t0-interval '2 hour' AND v.charttime<=c.t0
) mp ON true
WHERE c.weight>0 AND c.uo_rows>0 AND c.uo_6h>=0 AND c.twa_neq>0;

SELECT * FROM mimic_ratio_analysis ORDER BY analysis_row
\g (format=csv) 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/PRIVATE_WORK/mimic_ratio_analysis.csv'

SELECT * FROM mimic_cohort_flow
\g (format=csv) 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/CORRECTED_MANUSCRIPT_RESULTS_v1_1/02_DATA/cohort_flow_mimic.csv'

SELECT count(*) AS n,
       count(*) FILTER (WHERE clean_cohort) AS clean_n,
       count(*) FILTER (WHERE death28=1) AS deaths,
       count(*) FILTER (WHERE clean_cohort AND death28=1) AS clean_deaths,
       avg(active_prop) AS mean_active_prop,
       count(*) FILTER (WHERE active_prop>=0.5) AS active_ge50_n,
       count(*) FILTER (WHERE active_prop>=0.75) AS active_ge75_n
FROM mimic_ratio_analysis
\g (format=csv) 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/CORRECTED_MANUSCRIPT_RESULTS_v1_1/03_QC/mimic_ratio_extract_qc.csv'

ROLLBACK;
