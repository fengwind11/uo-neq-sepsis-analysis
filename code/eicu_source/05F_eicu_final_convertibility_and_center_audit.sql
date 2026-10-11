/*
File: 05F_eicu_final_convertibility_and_center_audit.sql
Purpose:
  Final targeted audit before formal extraction.
  Quantifies which vasopressor rows/stays/centers are usable from drugrate
  using the unit encoded in infusiondrug.drugname.

Important:
  - Does not apply NE-equivalent coefficients.
  - Does not convert ml/hr records.
  - ml/hr is marked unrecoverable unless a concentration source can be proven.
  - Uses drugrate as the charted dose/rate field.
*/

SET client_min_messages = NOTICE;
SET statement_timeout = '120min';

DROP TABLE IF EXISTS research_vasopressor_restart_eicu_v1.s16_core_rows;
CREATE TABLE research_vasopressor_restart_eicu_v1.s16_core_rows AS
SELECT
    i.infusiondrugid,
    i.patientunitstayid,
    p.hospitalid,
    i.infusionoffset,
    btrim(i.drugname) AS raw_drug_name,
    CASE
      WHEN lower(i.drugname) ~ '(norepinephrine|noradrenaline|levophed|levofed)'
        THEN 'norepinephrine'
      WHEN lower(i.drugname) ~ '(^|[^a-z])(epinephrine|adrenaline)([^a-z]|$)'
        THEN 'epinephrine'
      WHEN lower(i.drugname) ~ '(phenylephrine|neo[- ]?synephrine|neosynephrine)'
        THEN 'phenylephrine'
      WHEN lower(i.drugname) ~ 'dopamine'
        THEN 'dopamine'
      WHEN lower(i.drugname) ~ '(vasopressin|pitressin|argipressin)'
        THEN 'vasopressin'
    END AS agent,
    i.drugrate::text AS raw_drugrate,
    research_vasopressor_restart_eicu_v1.extract_numeric(i.drugrate::text) AS numeric_drugrate,
    CASE
      WHEN lower(i.drugname) LIKE '%mcg/kg/min%' THEN 'mcg_per_kg_min'
      WHEN lower(i.drugname) LIKE '%mcg/min%' THEN 'mcg_per_min'
      WHEN lower(i.drugname) LIKE '%mcg/kg/hr%' OR lower(i.drugname) LIKE '%mcg/kg/h)%'
        THEN 'mcg_per_kg_hour'
      WHEN lower(i.drugname) LIKE '%mcg/hr%' OR lower(i.drugname) LIKE '%mcg/h)%'
        THEN 'mcg_per_hour'
      WHEN lower(i.drugname) LIKE '%units/min%' OR lower(i.drugname) LIKE '%unit/min%'
        THEN 'units_per_min'
      WHEN lower(i.drugname) LIKE '%units/hr%' OR lower(i.drugname) LIKE '%unit/hr%'
        OR lower(i.drugname) LIKE '%units/hour%'
        THEN 'units_per_hour'
      WHEN lower(i.drugname) LIKE '%ml/hr%' OR lower(i.drugname) LIKE '%ml/h)%'
        THEN 'ml_per_hour'
      WHEN i.drugname ~ '\(\s*\)' THEN 'blank_unit'
      ELSE 'other_or_missing_unit'
    END AS unit_class,
    research_vasopressor_restart_eicu_v1.extract_numeric(p.admissionweight::text) AS admission_weight,
    research_vasopressor_restart_eicu_v1.extract_numeric(i.patientweight::text) AS infusion_weight,
    research_vasopressor_restart_eicu_v1.extract_numeric(p.dischargeweight::text) AS discharge_weight
FROM eicu_crd.infusiondrug i
JOIN eicu_crd.patient p USING (patientunitstayid)
WHERE lower(i.drugname) ~
 '(norepinephrine|noradrenaline|levophed|levofed|epinephrine|adrenaline|phenylephrine|neo[- ]?synephrine|neosynephrine|dopamine|vasopressin|pitressin|argipressin)';

CREATE INDEX IF NOT EXISTS idx_s16_core_rows_stay
ON research_vasopressor_restart_eicu_v1.s16_core_rows
(patientunitstayid, agent, infusionoffset);

DROP TABLE IF EXISTS research_vasopressor_restart_eicu_v1.s16_row_convertibility;
CREATE TABLE research_vasopressor_restart_eicu_v1.s16_row_convertibility AS
SELECT *,
    CASE
      WHEN admission_weight BETWEEN 20 AND 300 THEN admission_weight
      WHEN infusion_weight BETWEEN 20 AND 300 THEN infusion_weight
      WHEN discharge_weight BETWEEN 20 AND 300 THEN discharge_weight
      ELSE NULL
    END AS usable_weight,
    CASE
      WHEN numeric_drugrate IS NULL THEN 'unusable_non_numeric'
      WHEN unit_class IN ('mcg_per_kg_min','mcg_per_kg_hour','units_per_min','units_per_hour')
        THEN 'usable_direct'
      WHEN unit_class IN ('mcg_per_min','mcg_per_hour')
       AND (
         admission_weight BETWEEN 20 AND 300 OR
         infusion_weight BETWEEN 20 AND 300 OR
         discharge_weight BETWEEN 20 AND 300
       )
        THEN 'usable_with_weight'
      WHEN unit_class IN ('mcg_per_min','mcg_per_hour')
        THEN 'unusable_missing_weight'
      WHEN unit_class='ml_per_hour'
        THEN 'unusable_missing_concentration'
      WHEN unit_class='blank_unit'
        THEN 'unusable_blank_unit'
      ELSE 'unusable_other_unit'
    END AS convertibility
FROM research_vasopressor_restart_eicu_v1.s16_core_rows;

DROP TABLE IF EXISTS research_vasopressor_restart_eicu_v1.s16_agent_summary;
CREATE TABLE research_vasopressor_restart_eicu_v1.s16_agent_summary AS
SELECT
  agent,
  convertibility,
  count(*) AS records,
  count(DISTINCT patientunitstayid) AS stays,
  count(DISTINCT hospitalid) AS hospitals,
  round(
    100.0*count(*)/sum(count(*)) OVER(PARTITION BY agent),2
  ) AS percent_of_agent_records
FROM research_vasopressor_restart_eicu_v1.s16_row_convertibility
GROUP BY agent,convertibility
ORDER BY agent,records DESC;

DROP TABLE IF EXISTS research_vasopressor_restart_eicu_v1.s16_stay_convertibility;
CREATE TABLE research_vasopressor_restart_eicu_v1.s16_stay_convertibility AS
SELECT
  patientunitstayid,
  hospitalid,
  count(*) AS core_vaso_rows,
  count(*) FILTER(
    WHERE convertibility IN('usable_direct','usable_with_weight')
  ) AS usable_rows,
  count(*) FILTER(
    WHERE convertibility='unusable_missing_concentration'
  ) AS ml_per_hour_rows,
  count(DISTINCT agent) AS core_agents_present,
  count(DISTINCT agent) FILTER(
    WHERE convertibility IN('usable_direct','usable_with_weight')
  ) AS agents_with_usable_rows,
  round(
    100.0*count(*) FILTER(
      WHERE convertibility IN('usable_direct','usable_with_weight')
    )/NULLIF(count(*),0),2
  ) AS usable_row_percent,
  bool_and(
    convertibility IN('usable_direct','usable_with_weight')
  ) FILTER(WHERE numeric_drugrate IS NOT NULL AND numeric_drugrate>0)
    AS all_positive_rows_usable
FROM research_vasopressor_restart_eicu_v1.s16_row_convertibility
GROUP BY patientunitstayid,hospitalid;

DROP TABLE IF EXISTS research_vasopressor_restart_eicu_v1.s16_center_summary;
CREATE TABLE research_vasopressor_restart_eicu_v1.s16_center_summary AS
SELECT
  hospitalid,
  count(DISTINCT patientunitstayid) AS vaso_stays,
  count(*) AS core_vaso_rows,
  count(*) FILTER(
    WHERE convertibility IN('usable_direct','usable_with_weight')
  ) AS usable_rows,
  round(
    100.0*count(*) FILTER(
      WHERE convertibility IN('usable_direct','usable_with_weight')
    )/NULLIF(count(*),0),2
  ) AS usable_row_percent,
  count(DISTINCT patientunitstayid) FILTER(
    WHERE convertibility IN('usable_direct','usable_with_weight')
  ) AS stays_with_any_usable_row,
  count(DISTINCT patientunitstayid) FILTER(
    WHERE convertibility='unusable_missing_concentration'
  ) AS stays_with_ml_per_hour_rows,
  count(*) FILTER(WHERE agent='norepinephrine') AS norepinephrine_rows,
  count(*) FILTER(
    WHERE agent='norepinephrine'
      AND convertibility IN('usable_direct','usable_with_weight')
  ) AS usable_norepinephrine_rows,
  round(
    100.0*count(*) FILTER(
      WHERE agent='norepinephrine'
        AND convertibility IN('usable_direct','usable_with_weight')
    )/NULLIF(count(*) FILTER(WHERE agent='norepinephrine'),0),2
  ) AS usable_norepinephrine_percent
FROM research_vasopressor_restart_eicu_v1.s16_row_convertibility
GROUP BY hospitalid
ORDER BY hospitalid;

DROP TABLE IF EXISTS research_vasopressor_restart_eicu_v1.s16_center_eligibility;
CREATE TABLE research_vasopressor_restart_eicu_v1.s16_center_eligibility AS
SELECT *,
  CASE
    WHEN vaso_stays < 20 THEN 'too_few_vaso_stays'
    WHEN usable_norepinephrine_percent >= 90
     AND usable_row_percent >= 90
      THEN 'candidate_high_fidelity'
    WHEN usable_norepinephrine_percent >= 80
     AND usable_row_percent >= 80
      THEN 'candidate_moderate_fidelity'
    ELSE 'not_candidate_due_to_unit_coverage'
  END AS preliminary_center_status
FROM research_vasopressor_restart_eicu_v1.s16_center_summary;

DROP TABLE IF EXISTS research_vasopressor_restart_eicu_v1.s16_weight_summary;
CREATE TABLE research_vasopressor_restart_eicu_v1.s16_weight_summary AS
SELECT
  count(DISTINCT patientunitstayid) AS vaso_stays,
  count(DISTINCT patientunitstayid) FILTER(
    WHERE usable_weight BETWEEN 20 AND 300
  ) AS vaso_stays_with_usable_weight,
  round(
    100.0*count(DISTINCT patientunitstayid) FILTER(
      WHERE usable_weight BETWEEN 20 AND 300
    )/NULLIF(count(DISTINCT patientunitstayid),0),2
  ) AS usable_weight_percent
FROM research_vasopressor_restart_eicu_v1.s16_row_convertibility;

SELECT * FROM research_vasopressor_restart_eicu_v1.s16_agent_summary;
SELECT * FROM research_vasopressor_restart_eicu_v1.s16_weight_summary;
SELECT preliminary_center_status,count(*) AS centers,sum(vaso_stays) AS vaso_stays
FROM research_vasopressor_restart_eicu_v1.s16_center_eligibility
GROUP BY preliminary_center_status
ORDER BY preliminary_center_status;
