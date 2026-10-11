/*
06_eicu_vasopressor_normalization.sql

The conversion formula reproduces the historical MIMIC implementation:
NE-equivalent =
  norepinephrine
+ epinephrine
+ phenylephrine/10
+ dopamine/100
+ vasopressin(units/min)*2.5

All catecholamine rates are first normalized to microg/kg/min.
No concentration is imputed for mL/hour records.
*/
SET client_min_messages=NOTICE;
SET statement_timeout='180min';

DROP TABLE IF EXISTS research_vasopressor_restart_eicu_v1.e06_conversion_parameters;
CREATE TABLE research_vasopressor_restart_eicu_v1.e06_conversion_parameters(
 agent text PRIMARY KEY,
 ne_multiplier double precision,
 normalized_unit text,
 broad_qc_upper double precision,
 source_note text
);

INSERT INTO research_vasopressor_restart_eicu_v1.e06_conversion_parameters VALUES
('norepinephrine',1.0,'mcg/kg/min',5.0,'Historical MIMIC SQL; Goradia formula'),
('epinephrine',1.0,'mcg/kg/min',5.0,'Historical MIMIC SQL; Goradia formula'),
('phenylephrine',0.1,'mcg/kg/min',20.0,'Historical MIMIC SQL: dose/10'),
('dopamine',0.01,'mcg/kg/min',100.0,'Historical MIMIC SQL: dose/100'),
('vasopressin',2.5,'units/min',0.2,'Historical MIMIC SQL: units/min*2.5')
ON CONFLICT(agent) DO UPDATE SET
 ne_multiplier=excluded.ne_multiplier,
 normalized_unit=excluded.normalized_unit,
 broad_qc_upper=excluded.broad_qc_upper,
 source_note=excluded.source_note;

DROP TABLE IF EXISTS research_vasopressor_restart_eicu_v1.e06_normalized_rows;
CREATE TABLE research_vasopressor_restart_eicu_v1.e06_normalized_rows AS
WITH raw AS (
 SELECT
  i.infusiondrugid,
  i.patientunitstayid,
  p.hospitalid,
  i.infusionoffset,
  btrim(i.drugname) raw_drug_name,
  i.drugrate::text raw_drugrate,
  research_vasopressor_restart_eicu_v1.extract_numeric(i.drugrate::text) rate_num,
  CASE
   WHEN lower(i.drugname) ~ '(norepinephrine|noradrenaline|levophed|levofed)' THEN 'norepinephrine'
   WHEN lower(i.drugname) ~ '(^|[^a-z])(epinephrine|adrenaline)([^a-z]|$)' THEN 'epinephrine'
   WHEN lower(i.drugname) ~ '(phenylephrine|neo[- ]?synephrine|neosynephrine)' THEN 'phenylephrine'
   WHEN lower(i.drugname) ~ '(^|[^a-z])dopamine([^a-z]|$)' THEN 'dopamine'
   WHEN lower(i.drugname) ~ '(vasopressin|pitressin|argipressin)' THEN 'vasopressin'
  END agent,
  CASE
   WHEN lower(i.drugname) ~ '(mcg|ug|µg)/kg/min' THEN 'mcg_per_kg_min'
   WHEN lower(i.drugname) ~ '(mcg|ug|µg)/kg/(hr|hour)' THEN 'mcg_per_kg_hour'
   WHEN lower(i.drugname) ~ '(mcg|ug|µg)/(min|minute)' THEN 'mcg_per_min'
   WHEN lower(i.drugname) ~ '(mcg|ug|µg)/(hr|hour)' THEN 'mcg_per_hour'
   WHEN lower(i.drugname) ~ 'mg/(min|minute)' THEN 'mg_per_min'
   WHEN lower(i.drugname) ~ 'mg/(hr|hour)' THEN 'mg_per_hour'
   WHEN lower(i.drugname) ~ '(unit|units|u)/(min|minute)' THEN 'units_per_min'
   WHEN lower(i.drugname) ~ '(unit|units|u)/(hr|hour)' THEN 'units_per_hour'
   WHEN lower(i.drugname) ~ 'ml/(hr|hour)' THEN 'ml_per_hour'
   ELSE 'unresolved' END unit_class,
  CASE WHEN research_vasopressor_restart_eicu_v1.extract_numeric(p.admissionweight::text) BETWEEN 20 AND 300
       THEN research_vasopressor_restart_eicu_v1.extract_numeric(p.admissionweight::text)
       WHEN research_vasopressor_restart_eicu_v1.extract_numeric(i.patientweight::text) BETWEEN 20 AND 300
       THEN research_vasopressor_restart_eicu_v1.extract_numeric(i.patientweight::text)
       WHEN research_vasopressor_restart_eicu_v1.extract_numeric(p.dischargeweight::text) BETWEEN 20 AND 300
       THEN research_vasopressor_restart_eicu_v1.extract_numeric(p.dischargeweight::text)
  END weight_kg,
  CASE WHEN c.preliminary_center_status='candidate_high_fidelity' THEN 1 ELSE 0 END primary_center,
  CASE WHEN c.preliminary_center_status IN
             ('candidate_high_fidelity','candidate_moderate_fidelity')
       THEN 1 ELSE 0 END expanded_center
 FROM eicu_crd.infusiondrug i
 JOIN eicu_crd.patient p USING(patientunitstayid)
 JOIN research_vasopressor_restart_eicu_v1.s16_center_eligibility c USING(hospitalid)
 WHERE c.preliminary_center_status IN
       ('candidate_high_fidelity','candidate_moderate_fidelity')
   AND lower(i.drugname) ~
 '(norepinephrine|noradrenaline|levophed|levofed|epinephrine|adrenaline|phenylephrine|neo[- ]?synephrine|neosynephrine|(^|[^a-z])dopamine([^a-z]|$)|vasopressin|pitressin|argipressin)'
), norm AS (
 SELECT *,
 CASE
  WHEN rate_num=0 THEN 0
  WHEN rate_num<0 THEN NULL
  WHEN agent='vasopressin' AND unit_class='units_per_min' THEN rate_num
  WHEN agent='vasopressin' AND unit_class='units_per_hour' THEN rate_num/60.0
  WHEN agent<>'vasopressin' AND unit_class='mcg_per_kg_min' THEN rate_num
  WHEN agent<>'vasopressin' AND unit_class='mcg_per_kg_hour' THEN rate_num/60.0
  WHEN agent<>'vasopressin' AND unit_class='mcg_per_min' AND weight_kg IS NOT NULL
       THEN rate_num/weight_kg
  WHEN agent<>'vasopressin' AND unit_class='mcg_per_hour' AND weight_kg IS NOT NULL
       THEN rate_num/60.0/weight_kg
  WHEN agent<>'vasopressin' AND unit_class='mg_per_min' AND weight_kg IS NOT NULL
       THEN rate_num*1000.0/weight_kg
  WHEN agent<>'vasopressin' AND unit_class='mg_per_hour' AND weight_kg IS NOT NULL
       THEN rate_num*1000.0/60.0/weight_kg
 END normalized_rate
 FROM raw
)
SELECT n.*, p.ne_multiplier,p.broad_qc_upper,
       CASE WHEN normalized_rate>0
                  AND normalized_rate<=p.broad_qc_upper
            THEN normalized_rate*p.ne_multiplier END ne_eq_rate,
       CASE WHEN rate_num=0 THEN 1 ELSE 0 END explicit_zero,
       CASE WHEN normalized_rate>0
                  AND normalized_rate<=p.broad_qc_upper
            THEN 1 ELSE 0 END usable_positive_record,
       CASE
        WHEN rate_num IS NULL THEN 'non_numeric'
        WHEN rate_num<0 THEN 'negative'
        WHEN unit_class='ml_per_hour' THEN 'ml_per_hour_missing_concentration'
        WHEN unit_class='unresolved' THEN 'unresolved_unit'
        WHEN normalized_rate IS NULL AND rate_num>0 THEN 'conversion_missing'
        WHEN normalized_rate>p.broad_qc_upper THEN 'above_broad_qc_upper'
        ELSE NULL END exclusion_reason
FROM norm n
JOIN research_vasopressor_restart_eicu_v1.e06_conversion_parameters p USING(agent);

CREATE INDEX IF NOT EXISTS idx_e06_norm_stay_time
ON research_vasopressor_restart_eicu_v1.e06_normalized_rows
(patientunitstayid,agent,infusionoffset);

DROP TABLE IF EXISTS research_vasopressor_restart_eicu_v1.e06_normalization_qc;
CREATE TABLE research_vasopressor_restart_eicu_v1.e06_normalization_qc AS
SELECT hospitalid,primary_center,agent,unit_class,
       coalesce(exclusion_reason,'usable') status,
       count(*) records,count(DISTINCT patientunitstayid) stays
FROM research_vasopressor_restart_eicu_v1.e06_normalized_rows
GROUP BY hospitalid,primary_center,agent,unit_class,
         coalesce(exclusion_reason,'usable');
