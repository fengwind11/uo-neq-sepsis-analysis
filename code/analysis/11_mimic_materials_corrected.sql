\set ON_ERROR_STOP on
\pset pager off
SET statement_timeout='900s';
BEGIN;

CREATE TEMP TABLE a(
 analysis_row bigint, stay_id int, hadm_id int, subject_id int, t0 timestamp,
 death28 int, weight_kg double precision, urine_ml_6h double precision,
 uo_ml_kg_h double precision, twa_neq double precision, scaled_uo_neq double precision,
 age double precision, female int, baseline_creatinine double precision, ckd_proxy int,
 lactate_pre_t0 double precision, map_pre_t0 double precision, vent_primary int,
 anuria int, hospitalid int
);
\copy a FROM 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/PRIVATE_WORK/MANUSCRIPT_PREP_ANCHORS/mimic_anchor.csv' CSV HEADER
CREATE UNIQUE INDEX ON a(stay_id);
ANALYZE a;

CREATE TEMP TABLE mdx AS
SELECT a.stay_id,
 bool_or((x.icd_version=9 AND left(x.icd_code,3) BETWEEN '401' AND '405') OR (x.icd_version=10 AND left(x.icd_code,3) BETWEEN 'I10' AND 'I16')) AS hypertension,
 bool_or((x.icd_version=9 AND left(x.icd_code,3) BETWEEN '410' AND '414') OR (x.icd_version=10 AND left(x.icd_code,3) BETWEEN 'I20' AND 'I25')) AS ischemic_heart_disease
FROM a LEFT JOIN mimiciv_hosp.diagnoses_icd x ON x.hadm_id=a.hadm_id GROUP BY a.stay_id;

CREATE TEMP TABLE mvitals AS
SELECT a.stay_id,
 percentile_cont(0.5) WITHIN GROUP(ORDER BY x.heart_rate) FILTER(WHERE x.heart_rate BETWEEN 20 AND 250) heart_rate_pre_t0,
 percentile_cont(0.5) WITHIN GROUP(ORDER BY coalesce(x.sbp,x.sbp_ni)) FILTER(WHERE coalesce(x.sbp,x.sbp_ni) BETWEEN 40 AND 300) sbp_pre_t0,
 percentile_cont(0.5) WITHIN GROUP(ORDER BY x.mbp) FILTER(WHERE x.mbp BETWEEN 20 AND 200) map6_pre_t0
FROM a LEFT JOIN mimiciv_derived.vitalsign x ON x.stay_id=a.stay_id AND x.charttime BETWEEN a.t0-interval '6 hour' AND a.t0 GROUP BY a.stay_id;

CREATE TEMP TABLE mshock AS
SELECT DISTINCT ON(a.stay_id) a.stay_id,x.heart_rate/nullif(coalesce(x.sbp,x.sbp_ni),0) shock_index_pre_t0
FROM a JOIN mimiciv_derived.vitalsign x ON x.stay_id=a.stay_id AND x.charttime BETWEEN a.t0-interval '6 hour' AND a.t0
WHERE x.heart_rate BETWEEN 20 AND 250 AND coalesce(x.sbp,x.sbp_ni) BETWEEN 40 AND 300 ORDER BY a.stay_id,x.charttime DESC;

CREATE TEMP TABLE mlabc AS
SELECT a.stay_id,
 (array_agg(x.wbc ORDER BY x.charttime DESC) FILTER(WHERE x.wbc BETWEEN 0.1 AND 200))[1] wbc_pre_t0,
 (array_agg(x.platelet ORDER BY x.charttime DESC) FILTER(WHERE x.platelet BETWEEN 1 AND 2000))[1] platelet_pre_t0,
 (array_agg(x.hemoglobin ORDER BY x.charttime DESC) FILTER(WHERE x.hemoglobin BETWEEN 2 AND 25))[1] hemoglobin_pre_t0
FROM a LEFT JOIN mimiciv_derived.complete_blood_count x ON x.hadm_id=a.hadm_id AND x.charttime BETWEEN a.t0-interval '24 hour' AND a.t0 GROUP BY a.stay_id;
CREATE TEMP TABLE mlabchem AS
SELECT a.stay_id,(array_agg(x.bun ORDER BY x.charttime DESC) FILTER(WHERE x.bun BETWEEN 1 AND 300))[1] bun_pre_t0
FROM a LEFT JOIN mimiciv_derived.chemistry x ON x.hadm_id=a.hadm_id AND x.charttime BETWEEN a.t0-interval '24 hour' AND a.t0 GROUP BY a.stay_id;
CREATE TEMP TABLE mlabenzyme AS
SELECT a.stay_id,(array_agg(x.bilirubin_total ORDER BY x.charttime DESC) FILTER(WHERE x.bilirubin_total BETWEEN 0.01 AND 100))[1] bilirubin_pre_t0
FROM a LEFT JOIN mimiciv_derived.enzyme x ON x.hadm_id=a.hadm_id AND x.charttime BETWEEN a.t0-interval '24 hour' AND a.t0 GROUP BY a.stay_id;
CREATE TEMP TABLE mlabbg AS
SELECT a.stay_id,(array_agg(x.ph ORDER BY x.charttime DESC) FILTER(WHERE x.ph BETWEEN 6.5 AND 8.0))[1] ph_pre_t0
FROM a LEFT JOIN mimiciv_derived.bg x ON x.hadm_id=a.hadm_id AND x.charttime BETWEEN a.t0-interval '24 hour' AND a.t0 GROUP BY a.stay_id;

CREATE TEMP TABLE mpress_long AS
SELECT a.stay_id,v.agent,v.rate,x.starttime,x.endtime
FROM a JOIN mimiciv_derived.vasoactive_agent x ON x.stay_id=a.stay_id
  AND x.endtime>a.t0 AND x.starttime<a.t0+interval '6 hour'
CROSS JOIN LATERAL (VALUES
  ('norepinephrine',x.norepinephrine::double precision),
  ('epinephrine',x.epinephrine::double precision),
  ('vasopressin',x.vasopressin::double precision*2.5/60.0),
  ('phenylephrine',x.phenylephrine::double precision/10.0),
  ('dopamine',x.dopamine::double precision/100.0)
) v(agent,rate)
WHERE v.rate>0;
CREATE TEMP TABLE mpress AS
SELECT a.stay_id,
 max((p.agent='norepinephrine')::int) ne_use,max((p.agent='epinephrine')::int) epi_use,max((p.agent='vasopressin')::int) vaso_use,max((p.agent='phenylephrine')::int) pheny_use,max((p.agent='dopamine')::int) dopa_use,
 count(DISTINCT p.agent) pressor_agent_count,
 sum(p.rate*extract(epoch from (least(p.endtime,a.t0+interval '6 hour')-greatest(p.starttime,a.t0)))/21600.0) FILTER(WHERE p.agent='norepinephrine') ne_contrib,
 sum(p.rate*extract(epoch from (least(p.endtime,a.t0+interval '6 hour')-greatest(p.starttime,a.t0)))/21600.0) FILTER(WHERE p.agent='epinephrine') epi_contrib,
 sum(p.rate*extract(epoch from (least(p.endtime,a.t0+interval '6 hour')-greatest(p.starttime,a.t0)))/21600.0) FILTER(WHERE p.agent='vasopressin') vaso_contrib,
 sum(p.rate*extract(epoch from (least(p.endtime,a.t0+interval '6 hour')-greatest(p.starttime,a.t0)))/21600.0) FILTER(WHERE p.agent='phenylephrine') pheny_contrib,
 sum(p.rate*extract(epoch from (least(p.endtime,a.t0+interval '6 hour')-greatest(p.starttime,a.t0)))/21600.0) FILTER(WHERE p.agent='dopamine') dopa_contrib
FROM a LEFT JOIN mpress_long p USING(stay_id) GROUP BY a.stay_id;

CREATE TEMP TABLE mimic_enriched AS
SELECT a.*,COALESCE(ch.diabetes_without_cc,0)>0 OR COALESCE(ch.diabetes_with_cc,0)>0 diabetes,
 COALESCE(ch.congestive_heart_failure,0)>0 heart_failure,COALESCE(ch.chronic_pulmonary_disease,0)>0 chronic_pulmonary_disease,
 COALESCE(ch.mild_liver_disease,0)>0 OR COALESCE(ch.severe_liver_disease,0)>0 chronic_liver_disease,
 COALESCE(ch.malignant_cancer,0)>0 OR COALESCE(ch.metastatic_solid_tumor,0)>0 malignancy,
 dx.hypertension,dx.ischemic_heart_disease,v.heart_rate_pre_t0,v.sbp_pre_t0,v.map6_pre_t0,sp.shock_index_pre_t0,
 c.wbc_pre_t0,c.platelet_pre_t0,c.hemoglobin_pre_t0,cc.bun_pre_t0,e.bilirubin_pre_t0,b.ph_pre_t0,
 coalesce(p.ne_use,0) ne_use,coalesce(p.epi_use,0) epi_use,coalesce(p.vaso_use,0) vaso_use,coalesce(p.pheny_use,0) pheny_use,coalesce(p.dopa_use,0) dopa_use,coalesce(p.pressor_agent_count,0) pressor_agent_count,
 (coalesce(p.pressor_agent_count,0)>=2)::int pressor_ge2,d.los_icu::double precision icu_los_days,
 p.ne_contrib,p.epi_contrib,p.vaso_contrib,p.pheny_contrib,p.dopa_contrib,
 coalesce(p.ne_contrib,0)+coalesce(p.epi_contrib,0)+coalesce(p.vaso_contrib,0)+coalesce(p.pheny_contrib,0)+coalesce(p.dopa_contrib,0) nee_component_sum
FROM a LEFT JOIN mimiciv_derived.icustay_detail d ON d.stay_id=a.stay_id LEFT JOIN mimiciv_derived.charlson ch ON ch.hadm_id=a.hadm_id
LEFT JOIN mdx dx ON dx.stay_id=a.stay_id LEFT JOIN mvitals v ON v.stay_id=a.stay_id LEFT JOIN mshock sp ON sp.stay_id=a.stay_id
LEFT JOIN mlabc c ON c.stay_id=a.stay_id LEFT JOIN mlabchem cc ON cc.stay_id=a.stay_id LEFT JOIN mlabenzyme e ON e.stay_id=a.stay_id LEFT JOIN mlabbg b ON b.stay_id=a.stay_id LEFT JOIN mpress p ON p.stay_id=a.stay_id;

\copy (SELECT * FROM mimic_enriched ORDER BY analysis_row) TO 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/PRIVATE_WORK/mimic_manuscript_enriched.csv' CSV HEADER

SELECT row_number() over(order by a.analysis_row)::text AS audit_case_id,
       v.ventilation_status,
       round(extract(epoch from (v.starttime-a.t0))/60.0,1) AS start_min_from_t0,
       round(extract(epoch from (v.endtime-a.t0))/60.0,1) AS end_min_from_t0,
       a.vent_primary
 FROM a JOIN mimiciv_derived.ventilation v ON v.stay_id=a.stay_id
 WHERE v.starttime<=a.t0 AND v.endtime>a.t0
 ORDER BY a.analysis_row LIMIT 50
\g (format=csv) 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/CORRECTED_MANUSCRIPT_RESULTS_v1_1/02_HARMONIZATION/raw_spotchecks/mimic_vent_raw_50.csv'

SELECT row_number() over(order by a.analysis_row)::text AS audit_case_id,
       d.icd_version,d.icd_code,dd.long_title,a.ckd_proxy,
       coalesce(ch.renal_disease,0) AS charlson_renal_disease
 FROM a JOIN mimiciv_hosp.diagnoses_icd d ON d.hadm_id=a.hadm_id
 LEFT JOIN mimiciv_hosp.d_icd_diagnoses dd USING(icd_code,icd_version)
 LEFT JOIN mimiciv_derived.charlson ch ON ch.hadm_id=a.hadm_id
 WHERE (d.icd_version=9 AND (left(d.icd_code,3)='585' OR d.icd_code IN ('V451','V4511'))) OR
       (d.icd_version=10 AND (left(d.icd_code,3)='N18' OR d.icd_code='Z992'))
 ORDER BY a.analysis_row LIMIT 50
\g (format=csv) 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/CORRECTED_MANUSCRIPT_RESULTS_v1_1/02_HARMONIZATION/raw_spotchecks/mimic_ckd_raw_50.csv'

SELECT row_number() over(order by a.analysis_row)::text AS audit_case_id,
       round(extract(epoch from (x.charttime-a.t0))/60.0,1) AS minutes_from_t0,
       x.creatinine AS last_pre_t0_creatinine_mg_dl,a.baseline_creatinine AS frozen_baseline_creatinine_mg_dl,
       a.ckd_proxy
 FROM a JOIN LATERAL (SELECT charttime,creatinine FROM mimiciv_derived.chemistry c
   WHERE c.hadm_id=a.hadm_id AND c.charttime BETWEEN a.t0-interval '24 hour' AND a.t0
     AND c.creatinine>0 ORDER BY c.charttime DESC LIMIT 1) x ON true
 ORDER BY a.analysis_row LIMIT 50
\g (format=csv) 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/CORRECTED_MANUSCRIPT_RESULTS_v1_1/02_HARMONIZATION/raw_spotchecks/mimic_creatinine_raw_50.csv'

SELECT row_number() over(order by a.analysis_row)::text AS audit_case_id,
       s.sofa_score,round(extract(epoch from (s.sofa_time-a.t0))/60.0,1) AS sofa_time_min_from_t0,
       (s.sofa_time<=a.t0) AS timestamp_not_after_t0,
       'component timestamps not recoverable from this derived row; excluded from common expanded model' AS audit_note
 FROM a JOIN mimiciv_derived.sepsis3 s ON s.stay_id=a.stay_id
 ORDER BY a.analysis_row LIMIT 50
\g (format=csv) 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/CORRECTED_MANUSCRIPT_RESULTS_v1_1/02_HARMONIZATION/raw_spotchecks/mimic_sofa_raw_50.csv'

SELECT row_number() over(order by a.analysis_row,e.starttime,e.itemid)::text AS audit_case_id,
       e.itemid,di.label,e.amount,e.amountuom,
       round(extract(epoch from (e.starttime-a.t0))/60.0,1) AS start_min_from_t0,
       round(extract(epoch from (e.endtime-a.t0))/60.0,1) AS end_min_from_t0
 FROM a JOIN mimiciv_icu.inputevents e ON e.stay_id=a.stay_id
 LEFT JOIN mimiciv_icu.d_items di USING(itemid)
 WHERE e.endtime>a.t0 AND e.starttime<a.t0+interval '6 hour' AND e.amount IS NOT NULL
 ORDER BY a.analysis_row,e.starttime LIMIT 50
\g (format=csv) 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/CORRECTED_MANUSCRIPT_RESULTS_v1_1/02_HARMONIZATION/raw_spotchecks/mimic_fluid_input_raw_50.csv'

ROLLBACK;
