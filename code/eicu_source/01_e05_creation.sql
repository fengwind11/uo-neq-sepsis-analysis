/*
05_eicu_cohort_and_sepsis.sql
Operationally harmonized eICU Sepsis-3 candidate cohort.

Source schema: eicu_crd
Research schema: research_vasopressor_restart_eicu_v1

Definition:
- adult age >=18 years;
- first ICU stay per uniquepid;
- high-fidelity center for the primary replication;
- infection/sepsis diagnosis evidence;
- modified first-day SOFA >=2 using available eICU components.

This is an operational harmonization, not an exact reproduction of
mimiciv_derived.sepsis3.
*/
SET client_min_messages=NOTICE;
SET statement_timeout='180min';

CREATE SCHEMA IF NOT EXISTS research_vasopressor_restart_eicu_v1;

DROP TABLE IF EXISTS research_vasopressor_restart_eicu_v1.e05_centers;
CREATE TABLE research_vasopressor_restart_eicu_v1.e05_centers AS
SELECT hospitalid,
       preliminary_center_status,
       CASE WHEN preliminary_center_status='candidate_high_fidelity'
            THEN 1 ELSE 0 END AS primary_center,
       CASE WHEN preliminary_center_status IN
                 ('candidate_high_fidelity','candidate_moderate_fidelity')
            THEN 1 ELSE 0 END AS expanded_center
FROM research_vasopressor_restart_eicu_v1.s16_center_eligibility;

CREATE UNIQUE INDEX IF NOT EXISTS idx_e05_centers
ON research_vasopressor_restart_eicu_v1.e05_centers(hospitalid);

DROP TABLE IF EXISTS research_vasopressor_restart_eicu_v1.e05_adult_first_icu;
CREATE TABLE research_vasopressor_restart_eicu_v1.e05_adult_first_icu AS
WITH p AS (
 SELECT
   patientunitstayid,
   patienthealthsystemstayid,
   uniquepid,
   hospitalid,
   CASE WHEN age='> 89' THEN 90
        WHEN age ~ '^[0-9]+$' THEN age::int END AS age,
   gender,
   ethnicity,
   hospitaladmitsource,
   unitadmitsource,
   unittype,
   unitvisitnumber,
   unitdischargeoffset,
   hospitaldischargeoffset,
   unitdischargestatus,
   hospitaldischargestatus,
   admissionweight,
   dischargeweight,
   row_number() OVER(
     PARTITION BY uniquepid
     ORDER BY unitvisitnumber NULLS LAST, patientunitstayid
   ) AS rn
 FROM eicu_crd.patient
)
SELECT p.*, c.primary_center, c.expanded_center
FROM p
JOIN research_vasopressor_restart_eicu_v1.e05_centers c USING(hospitalid)
WHERE rn=1
  AND age>=18
  AND unitdischargeoffset>0
  AND c.expanded_center=1;

CREATE UNIQUE INDEX IF NOT EXISTS idx_e05_adult_first_icu
ON research_vasopressor_restart_eicu_v1.e05_adult_first_icu(patientunitstayid);

DROP TABLE IF EXISTS research_vasopressor_restart_eicu_v1.e05_infection_evidence;
CREATE TABLE research_vasopressor_restart_eicu_v1.e05_infection_evidence AS
WITH dx AS (
 SELECT patientunitstayid,
        diagnosisoffset AS evidence_offset,
        diagnosisstring AS evidence_text,
        'diagnosis'::text AS source_table
 FROM eicu_crd.diagnosis
 WHERE lower(coalesce(diagnosisstring,'')) ~
 '(sepsis|septic|infection|infectious|pneumonia|bacteremia|urosepsis|pyelonephritis|urinary tract infection|cholangitis|cholecystitis|meningitis|cellulitis|abscess|peritonitis|endocarditis|osteomyelitis|empyema|infected)'
 UNION ALL
 SELECT patientunitstayid,
        admitdxenteredoffset,
        coalesce(admitdxname,admitdxpath),
        'admissiondx'
 FROM eicu_crd.admissiondx
 WHERE lower(coalesce(admitdxname,'')||' '||coalesce(admitdxpath,'')) ~
 '(sepsis|septic|infection|infectious|pneumonia|bacteremia|urosepsis|pyelonephritis|urinary tract infection|cholangitis|cholecystitis|meningitis|cellulitis|abscess|peritonitis|endocarditis|osteomyelitis|empyema|infected)'
)
SELECT patientunitstayid,
       min(evidence_offset) AS infection_evidence_offset,
       count(*) AS evidence_rows,
       string_agg(DISTINCT source_table,',' ORDER BY source_table) AS evidence_sources
FROM dx
GROUP BY patientunitstayid;

CREATE UNIQUE INDEX IF NOT EXISTS idx_e05_infection
ON research_vasopressor_restart_eicu_v1.e05_infection_evidence(patientunitstayid);

DROP TABLE IF EXISTS research_vasopressor_restart_eicu_v1.e05_platelet24;
CREATE TABLE research_vasopressor_restart_eicu_v1.e05_platelet24 AS
SELECT patientunitstayid,
       min(labresult) FILTER(
         WHERE labresult BETWEEN 1 AND 2000
       ) AS platelet_min_24h
FROM eicu_crd.lab
WHERE labresultoffset BETWEEN 0 AND 1440
  AND lower(labname) ~ '(platelet|plt)'
GROUP BY patientunitstayid;

DROP TABLE IF EXISTS research_vasopressor_restart_eicu_v1.e05_firstday_vaso;
CREATE TABLE research_vasopressor_restart_eicu_v1.e05_firstday_vaso AS
SELECT patientunitstayid,
       max(ne_eq_rate) AS max_ne_eq_24h
FROM research_vasopressor_restart_eicu_v1.e06_normalized_rows
WHERE infusionoffset BETWEEN 0 AND 1440
  AND usable_positive_record=1
GROUP BY patientunitstayid;

DROP TABLE IF EXISTS research_vasopressor_restart_eicu_v1.e05_modified_sofa;
CREATE TABLE research_vasopressor_restart_eicu_v1.e05_modified_sofa AS
SELECT
 a.patientunitstayid,
 CASE
   WHEN av.pao2 IS NULL OR av.fio2 IS NULL OR av.fio2<=0 THEN 0
   WHEN av.fio2>1 THEN
     CASE
       WHEN av.pao2/(av.fio2/100.0)<100 AND coalesce(av.vent,0)=1 THEN 4
       WHEN av.pao2/(av.fio2/100.0)<200 AND coalesce(av.vent,0)=1 THEN 3
       WHEN av.pao2/(av.fio2/100.0)<300 THEN 2
       WHEN av.pao2/(av.fio2/100.0)<400 THEN 1 ELSE 0 END
   ELSE
     CASE
       WHEN av.pao2/av.fio2<100 AND coalesce(av.vent,0)=1 THEN 4
       WHEN av.pao2/av.fio2<200 AND coalesce(av.vent,0)=1 THEN 3
       WHEN av.pao2/av.fio2<300 THEN 2
       WHEN av.pao2/av.fio2<400 THEN 1 ELSE 0 END
 END AS sofa_resp,
 CASE
   WHEN pl.platelet_min_24h<20 THEN 4
   WHEN pl.platelet_min_24h<50 THEN 3
   WHEN pl.platelet_min_24h<100 THEN 2
   WHEN pl.platelet_min_24h<150 THEN 1 ELSE 0 END AS sofa_coag,
 CASE
   WHEN av.bilirubin>=12 THEN 4
   WHEN av.bilirubin>=6 THEN 3
   WHEN av.bilirubin>=2 THEN 2
   WHEN av.bilirubin>=1.2 THEN 1 ELSE 0 END AS sofa_liver,
 CASE
   WHEN coalesce(v.max_ne_eq_24h,0)>0.1 THEN 4
   WHEN coalesce(v.max_ne_eq_24h,0)>0 THEN 3
   WHEN av.meanbp<70 THEN 1 ELSE 0 END AS sofa_cardio,
 CASE
   WHEN (coalesce(av.eyes,0)+coalesce(av.motor,0)+coalesce(av.verbal,0))<6 THEN 4
   WHEN (coalesce(av.eyes,0)+coalesce(av.motor,0)+coalesce(av.verbal,0))<10 THEN 3
   WHEN (coalesce(av.eyes,0)+coalesce(av.motor,0)+coalesce(av.verbal,0))<13 THEN 2
   WHEN (coalesce(av.eyes,0)+coalesce(av.motor,0)+coalesce(av.verbal,0))<15 THEN 1
   ELSE 0 END AS sofa_cns,
 greatest(
   CASE
     WHEN av.creatinine>=5 THEN 4
     WHEN av.creatinine>=3.5 THEN 3
     WHEN av.creatinine>=2 THEN 2
     WHEN av.creatinine>=1.2 THEN 1 ELSE 0 END,
   CASE
     WHEN av.urine<200 THEN 4
     WHEN av.urine<500 THEN 3 ELSE 0 END
 ) AS sofa_renal
FROM research_vasopressor_restart_eicu_v1.e05_adult_first_icu a
LEFT JOIN eicu_crd.apacheapsvar av USING(patientunitstayid)
LEFT JOIN research_vasopressor_restart_eicu_v1.e05_platelet24 pl USING(patientunitstayid)
LEFT JOIN research_vasopressor_restart_eicu_v1.e05_firstday_vaso v USING(patientunitstayid);

ALTER TABLE research_vasopressor_restart_eicu_v1.e05_modified_sofa
ADD COLUMN sofa_total int;

UPDATE research_vasopressor_restart_eicu_v1.e05_modified_sofa
SET sofa_total=coalesce(sofa_resp,0)+coalesce(sofa_coag,0)+
               coalesce(sofa_liver,0)+coalesce(sofa_cardio,0)+
               coalesce(sofa_cns,0)+coalesce(sofa_renal,0);

DROP TABLE IF EXISTS research_vasopressor_restart_eicu_v1.e05_sepsis_cohort;
CREATE TABLE research_vasopressor_restart_eicu_v1.e05_sepsis_cohort AS
SELECT a.*, i.infection_evidence_offset, i.evidence_sources,
       s.sofa_total AS sepsis_sofa,
       s.sofa_resp,s.sofa_coag,s.sofa_liver,
       s.sofa_cardio,s.sofa_cns,s.sofa_renal
FROM research_vasopressor_restart_eicu_v1.e05_adult_first_icu a
JOIN research_vasopressor_restart_eicu_v1.e05_infection_evidence i USING(patientunitstayid)
JOIN research_vasopressor_restart_eicu_v1.e05_modified_sofa s USING(patientunitstayid)
WHERE s.sofa_total>=2;

CREATE UNIQUE INDEX IF NOT EXISTS idx_e05_sepsis_cohort
ON research_vasopressor_restart_eicu_v1.e05_sepsis_cohort(patientunitstayid);
