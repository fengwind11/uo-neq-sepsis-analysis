\set ON_ERROR_STOP on
\pset pager off
SET statement_timeout='900s';
BEGIN;

CREATE TEMP TABLE a(
 analysis_row bigint, stay_id int, hospital_stay_id int, hospitalid int, t0 int,
 death28 double precision, weight_kg double precision, urine_ml_6h double precision,
 uo_ml_kg_h double precision, twa_neq double precision, scaled_uo_neq double precision,
 age double precision, female int, baseline_creatinine double precision, ckd_proxy int,
 lactate_pre_t0 double precision, map_pre_t0 double precision, vent_primary int,
 anuria int
);
\copy a FROM 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/PRIVATE_WORK/MANUSCRIPT_PREP_ANCHORS/eicu_anchor.csv' CSV HEADER
CREATE UNIQUE INDEX ON a(stay_id);
ANALYZE a;

CREATE TEMP TABLE e_dx AS
SELECT a.stay_id,lower(coalesce(d.diagnosisstring,'')||' '||coalesce(d.icd9code,'')) AS txt
FROM a JOIN eicu_crd.diagnosis d ON d.patientunitstayid=a.stay_id AND d.diagnosisoffset<=a.t0;
CREATE INDEX ON e_dx(stay_id);
CREATE TEMP TABLE e_hx AS
SELECT a.stay_id,lower(coalesce(p.pasthistorypath,'')||' '||coalesce(p.pasthistoryvalue,'')||' '||coalesce(p.pasthistoryvaluetext,'')) AS txt
FROM a JOIN eicu_crd.pasthistory p ON p.patientunitstayid=a.stay_id;
CREATE INDEX ON e_hx(stay_id);

CREATE TEMP TABLE e_comorb AS
SELECT a.stay_id,
 EXISTS(SELECT 1 FROM e_dx x WHERE x.stay_id=a.stay_id AND x.txt ~ '(hypertension|hypertensive disease)') OR EXISTS(SELECT 1 FROM e_hx x WHERE x.stay_id=a.stay_id AND x.txt ~ '(hypertension requiring treatment|hypertension)') AS hypertension,
 EXISTS(SELECT 1 FROM e_dx x WHERE x.stay_id=a.stay_id AND x.txt ~ '(diabetes|diabetic)') OR EXISTS(SELECT 1 FROM e_hx x WHERE x.stay_id=a.stay_id AND x.txt ~ '(diabetes|diabetic)') AS diabetes,
 EXISTS(SELECT 1 FROM e_dx x WHERE x.stay_id=a.stay_id AND x.txt ~ '(chronic kidney disease|chronic renal failure|renal insufficiency)') OR EXISTS(SELECT 1 FROM e_hx x WHERE x.stay_id=a.stay_id AND x.txt ~ '(chronic kidney disease|chronic renal failure|renal insufficiency)') AS ckd_source_reviewed,
 EXISTS(SELECT 1 FROM e_dx x WHERE x.stay_id=a.stay_id AND x.txt ~ '(congestive heart failure|heart failure)') OR EXISTS(SELECT 1 FROM e_hx x WHERE x.stay_id=a.stay_id AND x.txt ~ '(congestive heart failure|heart failure| chf)') AS heart_failure,
 EXISTS(SELECT 1 FROM e_dx x WHERE x.stay_id=a.stay_id AND x.txt ~ '(coronary artery disease|ischemic heart disease|myocardial infarction)') OR EXISTS(SELECT 1 FROM e_hx x WHERE x.stay_id=a.stay_id AND x.txt ~ '(coronary artery|ischemic heart|myocardial infarction|coronary artery bypass|procedural coronary intervention)') AS ischemic_heart_disease,
 EXISTS(SELECT 1 FROM e_dx x WHERE x.stay_id=a.stay_id AND x.txt ~ '(chronic obstructive pulmonary|copd)') OR EXISTS(SELECT 1 FROM e_hx x WHERE x.stay_id=a.stay_id AND x.txt ~ '(/copd/|chronic obstructive pulmonary)') AS chronic_pulmonary_disease,
 EXISTS(SELECT 1 FROM e_dx x WHERE x.stay_id=a.stay_id AND x.txt ~ '(cirrhosis|chronic liver disease|hepatic failure)') OR EXISTS(SELECT 1 FROM e_hx x WHERE x.stay_id=a.stay_id AND x.txt ~ '(/cirrhosis/|chronic liver disease|hepatic failure)') AS chronic_liver_disease,
 EXISTS(SELECT 1 FROM e_dx x WHERE x.stay_id=a.stay_id AND x.txt ~ '(malignancy|cancer|carcinoma|leukemia|lymphoma)') OR EXISTS(SELECT 1 FROM e_hx x WHERE x.stay_id=a.stay_id AND x.txt ~ '(/cancer/|malignancy|carcinoma|leukemia|lymphoma)') AS malignancy,
 (SELECT count(*) FROM e_hx x WHERE x.stay_id=a.stay_id) AS past_history_rows
FROM a;

CREATE TEMP TABLE pressor_rows AS
SELECT a.stay_id,a.t0,n.*,
       lead(n.infusionoffset) OVER(PARTITION BY n.patientunitstayid,n.agent ORDER BY n.infusionoffset,n.infusiondrugid) AS next_offset
FROM a JOIN research_uo_neq_eicu_repair_v1.pressor_normalized_rows n ON n.patientunitstayid=a.stay_id
WHERE n.infusionoffset<a.t0+360;
CREATE INDEX ON pressor_rows(stay_id,agent,infusionoffset);

CREATE TEMP TABLE pressor_summary AS
SELECT a.stay_id,
 coalesce(bool_or(agent='norepinephrine' AND usable_positive_record=1 AND infusionoffset>=a.t0 AND infusionoffset<a.t0+360),false)::int AS ne_use,
 coalesce(bool_or(agent='epinephrine' AND usable_positive_record=1 AND infusionoffset>=a.t0 AND infusionoffset<a.t0+360),false)::int AS epi_use,
 coalesce(bool_or(agent='vasopressin' AND usable_positive_record=1 AND infusionoffset>=a.t0 AND infusionoffset<a.t0+360),false)::int AS vaso_use,
 coalesce(bool_or(agent='phenylephrine' AND usable_positive_record=1 AND infusionoffset>=a.t0 AND infusionoffset<a.t0+360),false)::int AS pheny_use,
 coalesce(bool_or(agent='dopamine' AND usable_positive_record=1 AND infusionoffset>=a.t0 AND infusionoffset<a.t0+360),false)::int AS dopa_use,
 count(DISTINCT agent) FILTER(WHERE usable_positive_record=1 AND infusionoffset>=a.t0 AND infusionoffset<a.t0+360) AS pressor_agent_count,
 sum(ne_eq_rate*greatest(0,least(coalesce(next_offset,infusionoffset+240),infusionoffset+240,a.t0+360)-greatest(infusionoffset,a.t0))/360.0) FILTER(WHERE agent='norepinephrine' AND usable_positive_record=1 AND infusionoffset<a.t0+360 AND coalesce(next_offset,infusionoffset+240)>a.t0) AS ne_contrib,
 sum(ne_eq_rate*greatest(0,least(coalesce(next_offset,infusionoffset+240),infusionoffset+240,a.t0+360)-greatest(infusionoffset,a.t0))/360.0) FILTER(WHERE agent='epinephrine' AND usable_positive_record=1 AND infusionoffset<a.t0+360 AND coalesce(next_offset,infusionoffset+240)>a.t0) AS epi_contrib,
 sum(ne_eq_rate*greatest(0,least(coalesce(next_offset,infusionoffset+240),infusionoffset+240,a.t0+360)-greatest(infusionoffset,a.t0))/360.0) FILTER(WHERE agent='vasopressin' AND usable_positive_record=1 AND infusionoffset<a.t0+360 AND coalesce(next_offset,infusionoffset+240)>a.t0) AS vaso_contrib,
 sum(ne_eq_rate*greatest(0,least(coalesce(next_offset,infusionoffset+240),infusionoffset+240,a.t0+360)-greatest(infusionoffset,a.t0))/360.0) FILTER(WHERE agent='phenylephrine' AND usable_positive_record=1 AND infusionoffset<a.t0+360 AND coalesce(next_offset,infusionoffset+240)>a.t0) AS pheny_contrib,
 sum(ne_eq_rate*greatest(0,least(coalesce(next_offset,infusionoffset+240),infusionoffset+240,a.t0+360)-greatest(infusionoffset,a.t0))/360.0) FILTER(WHERE agent='dopamine' AND usable_positive_record=1 AND infusionoffset<a.t0+360 AND coalesce(next_offset,infusionoffset+240)>a.t0) AS dopa_contrib
FROM a LEFT JOIN pressor_rows r USING(stay_id,t0) GROUP BY a.stay_id;

-- Rebuild component areas with the exact cap240 deduplication and conflict rules
-- used by 02_eicu_reextract.sql; record-use flags above intentionally differ.
CREATE TEMP TABLE e_dose_at_time AS
SELECT n.patientunitstayid AS stay_id,n.agent,n.infusionoffset,
       max(n.ne_eq_rate) FILTER(WHERE n.usable_positive_record=1) AS dose_neq,
       bool_or(n.explicit_zero=1) AS has_explicit_zero,
       bool_or(n.exclusion_reason IS NOT NULL AND coalesce(n.rate_num,0)>0) AS has_unusable_positive,
       count(DISTINCT n.ne_eq_rate) FILTER(WHERE n.usable_positive_record=1) AS distinct_positive_doses
FROM research_uo_neq_eicu_repair_v1.pressor_normalized_rows n
JOIN a ON a.stay_id=n.patientunitstayid
GROUP BY n.patientunitstayid,n.agent,n.infusionoffset;
CREATE TEMP TABLE e_dose_seq AS
SELECT d.*,
       ((d.has_explicit_zero AND d.dose_neq>0) OR d.distinct_positive_doses>1) AS same_offset_dose_conflict,
       lead(d.infusionoffset) OVER(PARTITION BY d.stay_id,d.agent ORDER BY d.infusionoffset) AS next_offset,
       p.unitdischargeoffset
FROM e_dose_at_time d JOIN eicu_crd.patient p ON p.patientunitstayid=d.stay_id;
CREATE TEMP TABLE e_contrib AS
WITH intervals AS (
  SELECT d.stay_id,d.agent,d.infusionoffset AS start_offset,d.dose_neq,
         least(coalesce(d.next_offset,d.infusionoffset+240),d.infusionoffset+240,d.unitdischargeoffset) AS end_offset
  FROM e_dose_seq d
  WHERE d.dose_neq>0 AND NOT d.has_unusable_positive AND NOT d.same_offset_dose_conflict
), area AS (
  SELECT a.stay_id,i.agent,
         sum(i.dose_neq*greatest(0,least(i.end_offset,a.t0+360)-greatest(i.start_offset,a.t0))/360.0) AS twa_component
  FROM a JOIN intervals i ON i.stay_id=a.stay_id AND i.start_offset<a.t0+360 AND i.end_offset>a.t0
  GROUP BY a.stay_id,i.agent
)
SELECT stay_id,
       sum(twa_component) FILTER(WHERE agent='norepinephrine') AS ne_contrib,
       sum(twa_component) FILTER(WHERE agent='epinephrine') AS epi_contrib,
       sum(twa_component) FILTER(WHERE agent='vasopressin') AS vaso_contrib,
       sum(twa_component) FILTER(WHERE agent='phenylephrine') AS pheny_contrib,
       sum(twa_component) FILTER(WHERE agent='dopamine') AS dopa_contrib
FROM area GROUP BY stay_id;
UPDATE pressor_summary ps SET
  ne_contrib=c.ne_contrib,epi_contrib=c.epi_contrib,vaso_contrib=c.vaso_contrib,
  pheny_contrib=c.pheny_contrib,dopa_contrib=c.dopa_contrib
FROM e_contrib c WHERE ps.stay_id=c.stay_id;

CREATE TEMP TABLE ehr AS
SELECT a.stay_id,x.heartrate::double precision val FROM a JOIN eicu_crd.vitalperiodic x ON x.patientunitstayid=a.stay_id AND x.observationoffset BETWEEN a.t0-360 AND a.t0 WHERE x.heartrate BETWEEN 20 AND 250
UNION ALL
SELECT a.stay_id,n.nursingchartvalue::double precision FROM a JOIN eicu_crd.nursecharting n ON n.patientunitstayid=a.stay_id AND n.nursingchartoffset BETWEEN a.t0-360 AND a.t0
WHERE lower(n.nursingchartcelltypevallabel)='heart rate' AND btrim(n.nursingchartvalue) ~ '^[0-9]+([.][0-9]+)?$' AND n.nursingchartvalue::double precision BETWEEN 20 AND 250;
CREATE TEMP TABLE esbp_raw AS
SELECT a.stay_id,x.observationoffset AS source_offset,x.systemicsystolic::double precision AS val,
       1 AS source_rank,'vitalPeriodic.systemicSystolic'::text AS source_name
FROM a JOIN eicu_crd.vitalperiodic x ON x.patientunitstayid=a.stay_id
  AND x.observationoffset BETWEEN a.t0-360 AND a.t0
WHERE x.systemicsystolic BETWEEN 40 AND 300
UNION ALL
SELECT a.stay_id,n.nursingchartoffset,n.nursingchartvalue::double precision,
       CASE WHEN lower(n.nursingchartcelltypevallabel)='invasive bp' THEN 2 ELSE 3 END,
       n.nursingchartcelltypevalname
FROM a JOIN eicu_crd.nursecharting n ON n.patientunitstayid=a.stay_id
  AND n.nursingchartoffset BETWEEN a.t0-360 AND a.t0
WHERE lower(n.nursingchartcelltypevalname) IN ('invasive bp systolic','non-invasive bp systolic')
  AND btrim(n.nursingchartvalue) ~ '^[0-9]+([.][0-9]+)?$'
  AND n.nursingchartvalue::double precision BETWEEN 40 AND 300;
CREATE TEMP TABLE esbp AS
SELECT DISTINCT ON (stay_id,source_offset) stay_id,source_offset,val,source_name,source_rank,source_rows,source_min,source_max
FROM (
  SELECT stay_id,source_offset,source_rank,source_name,
         percentile_cont(0.5) WITHIN GROUP(ORDER BY val) AS val,
         count(*) AS source_rows,min(val) AS source_min,max(val) AS source_max
  FROM esbp_raw GROUP BY 1,2,3,4
) x
ORDER BY stay_id,source_offset,source_rank,source_name;
CREATE TEMP TABLE esbp_old AS
SELECT a.stay_id,x.systemicsystolic::double precision val
FROM a JOIN eicu_crd.vitalperiodic x ON x.patientunitstayid=a.stay_id
  AND x.observationoffset BETWEEN a.t0-360 AND a.t0 WHERE x.systemicsystolic BETWEEN 40 AND 300
UNION ALL
SELECT a.stay_id,split_part(n.nursingchartvalue,'/',1)::double precision
FROM a JOIN eicu_crd.nursecharting n ON n.patientunitstayid=a.stay_id
  AND n.nursingchartoffset BETWEEN a.t0-360 AND a.t0
WHERE lower(n.nursingchartcelltypevallabel) IN ('non-invasive bp','invasive bp')
  AND split_part(btrim(n.nursingchartvalue),'/',1) ~ '^[0-9]+([.][0-9]+)?$'
  AND split_part(n.nursingchartvalue,'/',1)::double precision BETWEEN 40 AND 300;
CREATE TEMP TABLE evitals AS
SELECT a.stay_id,h.heart_rate_pre_t0,s.sbp_pre_t0,m.map6_pre_t0
FROM a LEFT JOIN (SELECT stay_id,percentile_cont(0.5) WITHIN GROUP(ORDER BY val) heart_rate_pre_t0 FROM ehr GROUP BY stay_id) h ON h.stay_id=a.stay_id
LEFT JOIN (SELECT stay_id,percentile_cont(0.5) WITHIN GROUP(ORDER BY val) sbp_pre_t0 FROM esbp GROUP BY stay_id) s ON s.stay_id=a.stay_id
LEFT JOIN (SELECT a.stay_id,percentile_cont(0.5) WITHIN GROUP(ORDER BY x.systemicmean) FILTER(WHERE x.systemicmean BETWEEN 20 AND 200) map6_pre_t0 FROM a LEFT JOIN eicu_crd.vitalperiodic x ON x.patientunitstayid=a.stay_id AND x.observationoffset BETWEEN a.t0-360 AND a.t0 GROUP BY a.stay_id) m ON m.stay_id=a.stay_id;
CREATE TEMP TABLE eshock AS SELECT stay_id,heart_rate_pre_t0/nullif(sbp_pre_t0,0) shock_index_pre_t0 FROM evitals;
CREATE TEMP TABLE esbp_change AS
SELECT a.analysis_row,a.stay_id,a.t0,v.heart_rate_pre_t0,
       o.old_sbp,v.sbp_pre_t0 AS corrected_sbp,o.old_records,n.new_records,
       v.heart_rate_pre_t0/nullif(o.old_sbp,0) AS old_shock_index,
       v.heart_rate_pre_t0/nullif(v.sbp_pre_t0,0) AS corrected_shock_index
FROM a LEFT JOIN evitals v USING(stay_id)
LEFT JOIN (SELECT stay_id,percentile_cont(0.5) WITHIN GROUP(ORDER BY val) old_sbp,count(*) old_records FROM esbp_old GROUP BY stay_id) o USING(stay_id)
LEFT JOIN (SELECT stay_id,count(*) new_records FROM esbp GROUP BY stay_id) n USING(stay_id);
SELECT count(*) AS cohort_n,
       count(*) FILTER(WHERE old_sbp IS DISTINCT FROM corrected_sbp) AS changed_patient_n,
       count(*) FILTER(WHERE old_sbp IS NOT NULL AND corrected_sbp IS NULL) AS became_missing_n,
       count(*) FILTER(WHERE old_sbp IS NULL AND corrected_sbp IS NOT NULL) AS became_observed_n,
       sum(old_records) AS old_record_n,sum(new_records) AS corrected_timepoint_n,
       percentile_cont(ARRAY[0.01,0.25,0.5,0.75,0.99]) WITHIN GROUP(ORDER BY corrected_sbp-old_sbp) AS delta_sbp_p01_p25_p50_p75_p99
FROM esbp_change
\g (format=csv) 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/CORRECTED_MANUSCRIPT_RESULTS_v1_1/01_SOURCE_LINEAGE/eicu_sbp_change_summary.csv'
SELECT analysis_row,old_sbp,corrected_sbp,old_records,new_records,old_shock_index,corrected_shock_index
FROM esbp_change ORDER BY analysis_row
\g (format=csv) 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/PRIVATE_WORK/eicu_sbp_change_by_case.csv'
SELECT c.analysis_row,c.stay_id,c.t0,c.old_sbp,c.corrected_sbp,c.old_shock_index,c.corrected_shock_index,
       r.source_offset,r.source_name,r.source_rank,r.val,r.source_rows,r.source_min,r.source_max
FROM (SELECT * FROM esbp_change WHERE old_sbp IS DISTINCT FROM corrected_sbp ORDER BY md5(stay_id::text||':SBP20260930') LIMIT 30) c
JOIN esbp r USING(stay_id) ORDER BY c.analysis_row,r.source_offset,r.source_rank
\g (format=csv) 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/PRIVATE_WORK/eicu_sbp_raw_trace_30_cases.csv'
CREATE TEMP TABLE elabs AS
SELECT a.stay_id,
 (array_agg(x.labresult ORDER BY x.labresultoffset DESC) FILTER(WHERE lower(x.labname)='wbc x 1000' AND lower(coalesce(x.labmeasurenamesystem,''))='k/mcl' AND x.labresult BETWEEN 0.1 AND 200))[1] wbc_pre_t0,
 (array_agg(x.labresult ORDER BY x.labresultoffset DESC) FILTER(WHERE lower(x.labname)='platelets x 1000' AND lower(coalesce(x.labmeasurenamesystem,''))='k/mcl' AND x.labresult BETWEEN 1 AND 2000))[1] platelet_pre_t0,
 (array_agg(x.labresult ORDER BY x.labresultoffset DESC) FILTER(WHERE lower(x.labname)='hgb' AND lower(coalesce(x.labmeasurenamesystem,''))='g/dl' AND x.labresult BETWEEN 2 AND 25))[1] hemoglobin_pre_t0,
 (array_agg(x.labresult ORDER BY x.labresultoffset DESC) FILTER(WHERE lower(x.labname)='bun' AND lower(coalesce(x.labmeasurenamesystem,''))='mg/dl' AND x.labresult BETWEEN 1 AND 300))[1] bun_pre_t0,
 (array_agg(x.labresult ORDER BY x.labresultoffset DESC) FILTER(WHERE lower(x.labname)='total bilirubin' AND lower(coalesce(x.labmeasurenamesystem,''))='mg/dl' AND x.labresult BETWEEN 0.01 AND 100))[1] bilirubin_pre_t0,
 (array_agg(x.labresult ORDER BY x.labresultoffset DESC) FILTER(WHERE lower(x.labname)='ph' AND x.labresult BETWEEN 6.5 AND 8.0))[1] ph_pre_t0
FROM a LEFT JOIN eicu_crd.lab x ON x.patientunitstayid=a.stay_id AND x.labresultoffset BETWEEN a.t0-1440 AND a.t0
 AND lower(x.labname) IN ('wbc x 1000','platelets x 1000','hgb','bun','total bilirubin','ph') GROUP BY a.stay_id;
CREATE TEMP TABLE event AS
SELECT a.stay_id,((rc.stay_id IS NOT NULL) OR (tx.stay_id IS NOT NULL))::int vent_source_reviewed,
 (rc.stay_id IS NOT NULL)::int vent_respiratorycare,(tx.stay_id IS NOT NULL)::int vent_treatment
FROM a LEFT JOIN (
 SELECT DISTINCT a.stay_id FROM a JOIN eicu_crd.respiratorycare r ON r.patientunitstayid=a.stay_id
 WHERE lower(coalesce(r.airwaytype,'')) IN ('oral ett','nasal ett','tracheostomy')
 AND coalesce(r.ventstartoffset,r.priorventstartoffset,r.respcarestatusoffset)<=a.t0
 AND (nullif(r.ventendoffset,0) IS NULL OR r.ventendoffset>=a.t0)
) rc ON rc.stay_id=a.stay_id LEFT JOIN (
 SELECT DISTINCT a.stay_id FROM a JOIN eicu_crd.treatment t ON t.patientunitstayid=a.stay_id
 WHERE t.treatmentoffset BETWEEN a.t0-360 AND a.t0 AND lower(t.treatmentstring) LIKE '%mechanical ventilation%' AND lower(t.treatmentstring) NOT LIKE '%non-invasive%'
) tx ON tx.stay_id=a.stay_id;
CREATE TEMP TABLE efluid AS
SELECT a.stay_id,(count(io.intakeoutputid)>0)::int any_io_0_6h,(count(*) FILTER(WHERE io.intaketotal IS NOT NULL)>0)::int any_intaketotal_0_6h,
 (count(*) FILTER(WHERE io.nettotal IS NOT NULL)>0)::int any_nettotal_0_6h
FROM a LEFT JOIN eicu_crd.intakeoutput io ON io.patientunitstayid=a.stay_id AND io.intakeoutputoffset BETWEEN a.t0 AND a.t0+360 GROUP BY a.stay_id;

CREATE TEMP TABLE eicu_enriched AS
SELECT a.*,c.hypertension,c.diabetes,c.ckd_source_reviewed,c.heart_failure,
       c.ischemic_heart_disease,c.chronic_pulmonary_disease,c.chronic_liver_disease,
       c.malignancy,c.past_history_rows,
       p.admissionheight::double precision AS height_cm,
       CASE WHEN p.admissionheight BETWEEN 100 AND 250 THEN a.weight_kg/power(p.admissionheight/100.0,2) END AS bmi,
       v.heart_rate_pre_t0,v.sbp_pre_t0,v.map6_pre_t0,sp.shock_index_pre_t0,
       lab.wbc_pre_t0,lab.platelet_pre_t0,lab.hemoglobin_pre_t0,lab.bun_pre_t0,lab.bilirubin_pre_t0,lab.ph_pre_t0,
       vent.vent_source_reviewed,vent.vent_respiratorycare,vent.vent_treatment,
       ps.ne_use,ps.epi_use,ps.vaso_use,ps.pheny_use,ps.dopa_use,ps.pressor_agent_count,
       (ps.pressor_agent_count>=2)::int AS pressor_ge2,
       p.unitdischargeoffset/1440.0 AS icu_los_days,
       ps.ne_contrib,ps.epi_contrib,ps.vaso_contrib,ps.pheny_contrib,ps.dopa_contrib,
       (coalesce(ps.ne_contrib,0)+coalesce(ps.epi_contrib,0)+coalesce(ps.vaso_contrib,0)+coalesce(ps.pheny_contrib,0)+coalesce(ps.dopa_contrib,0)) AS nee_component_sum,
       fluid.any_io_0_6h,fluid.any_intaketotal_0_6h,fluid.any_nettotal_0_6h
FROM a
JOIN eicu_crd.patient p ON p.patientunitstayid=a.stay_id
JOIN e_comorb c ON c.stay_id=a.stay_id LEFT JOIN evitals v ON v.stay_id=a.stay_id LEFT JOIN eshock sp ON sp.stay_id=a.stay_id
LEFT JOIN elabs lab ON lab.stay_id=a.stay_id LEFT JOIN event vent ON vent.stay_id=a.stay_id
JOIN pressor_summary ps ON ps.stay_id=a.stay_id LEFT JOIN efluid fluid ON fluid.stay_id=a.stay_id;

\copy (SELECT * FROM eicu_enriched ORDER BY analysis_row) TO 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/PRIVATE_WORK/eicu_manuscript_enriched.csv' CSV HEADER

SELECT hospitalid,count(*) n,
       sum(any_io_0_6h) any_io_n,round(100.0*avg(any_io_0_6h),2) any_io_percent,
       sum(any_intaketotal_0_6h) intaketotal_n,round(100.0*avg(any_intaketotal_0_6h),2) intaketotal_percent,
       sum(any_nettotal_0_6h) nettotal_n,round(100.0*avg(any_nettotal_0_6h),2) nettotal_percent
 FROM eicu_enriched GROUP BY hospitalid ORDER BY hospitalid
\g (format=csv) 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/CORRECTED_MANUSCRIPT_RESULTS_v1_1/04_PRESSOR/eicu_fluid_hospital_coverage.csv'

WITH z AS (
 SELECT a.analysis_row,'respiratorycare' source,r.airwaytype raw_label,r.respcarestatusoffset source_offset,
        r.ventstartoffset,r.ventendoffset,null::text treatmentstring,a.vent_primary,
        (lower(coalesce(r.airwaytype,'')) IN ('oral ett','nasal ett','tracheostomy') AND coalesce(r.ventstartoffset,r.priorventstartoffset,r.respcarestatusoffset)<=a.t0 AND (nullif(r.ventendoffset,0) IS NULL OR r.ventendoffset>=a.t0))::int source_reviewed_flag
 FROM a JOIN eicu_crd.respiratorycare r ON r.patientunitstayid=a.stay_id
 WHERE lower(coalesce(r.airwaytype,'')) IN ('oral ett','nasal ett','tracheostomy') AND coalesce(r.ventstartoffset,r.priorventstartoffset,r.respcarestatusoffset)<=a.t0
 UNION ALL
 SELECT a.analysis_row,'treatment',null,t.treatmentoffset,null,null,t.treatmentstring,a.vent_primary,1
 FROM a JOIN eicu_crd.treatment t ON t.patientunitstayid=a.stay_id
 WHERE t.treatmentoffset BETWEEN a.t0-360 AND a.t0 AND lower(t.treatmentstring) LIKE '%mechanical ventilation%' AND lower(t.treatmentstring) NOT LIKE '%non-invasive%'
 ) SELECT row_number() over(order by analysis_row,source,source_offset)::text audit_case_id,source,raw_label,source_offset,ventstartoffset,ventendoffset,treatmentstring,vent_primary,source_reviewed_flag FROM z ORDER BY analysis_row,source,source_offset LIMIT 60
\g (format=csv) 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/CORRECTED_MANUSCRIPT_RESULTS_v1_1/02_HARMONIZATION/raw_spotchecks/eicu_vent_raw_60.csv'

WITH z AS (
 SELECT a.analysis_row,'diagnosis' source,d.diagnosisoffset source_offset,d.diagnosisstring raw_text,a.ckd_proxy
 FROM a JOIN eicu_crd.diagnosis d ON d.patientunitstayid=a.stay_id AND d.diagnosisoffset<=a.t0
 WHERE lower(coalesce(d.diagnosisstring,'')) ~ '(chronic kidney disease|chronic renal failure|renal insufficiency)'
 UNION ALL
 SELECT a.analysis_row,'pasthistory',p.pasthistoryoffset,p.pasthistorypath||' | '||coalesce(p.pasthistoryvalue,''),a.ckd_proxy
 FROM a JOIN eicu_crd.pasthistory p ON p.patientunitstayid=a.stay_id
 WHERE lower(coalesce(p.pasthistorypath,'')||' '||coalesce(p.pasthistoryvalue,'')) ~ '(chronic kidney disease|chronic renal failure|renal insufficiency)'
 ) SELECT row_number() over(order by analysis_row,source,source_offset)::text audit_case_id,source,source_offset,raw_text,ckd_proxy FROM z ORDER BY analysis_row,source,source_offset LIMIT 60
\g (format=csv) 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/CORRECTED_MANUSCRIPT_RESULTS_v1_1/02_HARMONIZATION/raw_spotchecks/eicu_ckd_raw_60.csv'

SELECT row_number() over(order by a.analysis_row)::text audit_case_id,
       x.labresultoffset-a.t0 minutes_from_t0,x.labname,x.labresult,x.labmeasurenamesystem,
       a.baseline_creatinine frozen_last_pre_t0_creatinine,a.ckd_proxy
 FROM a JOIN LATERAL (SELECT * FROM eicu_crd.lab l WHERE l.patientunitstayid=a.stay_id
   AND lower(l.labname)='creatinine' AND lower(coalesce(l.labmeasurenamesystem,''))='mg/dl'
   AND l.labresultoffset BETWEEN a.t0-1440 AND a.t0 AND l.labresult>0 ORDER BY l.labresultoffset DESC LIMIT 1) x ON true
 ORDER BY a.analysis_row LIMIT 50
\g (format=csv) 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/CORRECTED_MANUSCRIPT_RESULTS_v1_1/02_HARMONIZATION/raw_spotchecks/eicu_creatinine_raw_50.csv'

SELECT row_number() over(order by a.analysis_row)::text audit_case_id,s.sepsis_sofa,s.sofa_resp,s.sofa_coag,s.sofa_liver,s.sofa_cardio,s.sofa_cns,s.sofa_renal,
       s.infection_evidence_offset-a.t0 infection_evidence_min_from_t0,
       'component observation timestamps not retained in cohort table; excluded from common expanded model' audit_note
 FROM a JOIN research_vasopressor_restart_eicu_v1.e05_sepsis_cohort s ON s.patientunitstayid=a.stay_id
 ORDER BY a.analysis_row LIMIT 50
\g (format=csv) 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/CORRECTED_MANUSCRIPT_RESULTS_v1_1/02_HARMONIZATION/raw_spotchecks/eicu_sofa_raw_50.csv'

SELECT row_number() over(order by a.analysis_row,io.intakeoutputoffset,io.intakeoutputid)::text audit_case_id,
       io.intakeoutputoffset-a.t0 minutes_from_t0,io.intaketotal,io.outputtotal,io.nettotal,io.cellpath,io.celllabel,io.cellvaluenumeric,io.cellvaluetext
 FROM a JOIN eicu_crd.intakeoutput io ON io.patientunitstayid=a.stay_id
 WHERE io.intakeoutputoffset BETWEEN a.t0 AND a.t0+360
 ORDER BY a.analysis_row,io.intakeoutputoffset LIMIT 60
\g (format=csv) 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/CORRECTED_MANUSCRIPT_RESULTS_v1_1/02_HARMONIZATION/raw_spotchecks/eicu_fluid_raw_60.csv'

ROLLBACK;
