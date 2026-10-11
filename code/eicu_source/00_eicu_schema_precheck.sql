/*
Stage 1 eICU-CRD precheck
File: 00_eicu_schema_precheck.sql
Reads source data only. Generated objects are confined to:
research_vasopressor_restart_eicu_v1
*/

SET client_min_messages = NOTICE;
SET statement_timeout = '30min';
SET lock_timeout = '10s';

CREATE SCHEMA IF NOT EXISTS research_vasopressor_restart_eicu_v1;

CREATE TABLE IF NOT EXISTS research_vasopressor_restart_eicu_v1.run_config (
    config_key text PRIMARY KEY,
    config_value text NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE IF NOT EXISTS research_vasopressor_restart_eicu_v1.audit_run_log (
    log_id bigserial PRIMARY KEY,
    script_name text NOT NULL,
    log_level text NOT NULL,
    message text NOT NULL,
    logged_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

INSERT INTO research_vasopressor_restart_eicu_v1.audit_run_log
(script_name, log_level, message)
VALUES ('00_eicu_schema_precheck.sql','INFO','Started');

DO $detect$
DECLARE
    -- Optional override, e.g. 'eicu_crd'. Leave NULL for auto-detection.
    v_source_schema_override text := NULL;
    v_source_schema text;
BEGIN
    IF v_source_schema_override IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM information_schema.tables
            WHERE table_schema=v_source_schema_override
              AND lower(table_name)='patient'
        ) THEN
            RAISE EXCEPTION 'Schema % does not contain patient table',
                v_source_schema_override;
        END IF;
        v_source_schema := v_source_schema_override;
    ELSE
        SELECT x.table_schema INTO v_source_schema
        FROM (
            SELECT table_schema,
                   sum(CASE lower(table_name)
                       WHEN 'patient' THEN 100
                       WHEN 'infusiondrug' THEN 40
                       WHEN 'medication' THEN 20
                       WHEN 'diagnosis' THEN 15
                       WHEN 'lab' THEN 15
                       WHEN 'microlab' THEN 10
                       WHEN 'vitalperiodic' THEN 10
                       WHEN 'vitalaperiodic' THEN 10
                       ELSE 0 END) AS score
            FROM information_schema.tables
            WHERE table_type='BASE TABLE'
              AND table_schema NOT IN ('pg_catalog','information_schema',
                                       'research_vasopressor_restart_eicu_v1')
            GROUP BY table_schema
        ) x
        WHERE EXISTS (
            SELECT 1 FROM information_schema.tables p
            WHERE p.table_schema=x.table_schema AND lower(p.table_name)='patient'
        )
        ORDER BY x.score DESC, x.table_schema
        LIMIT 1;
    END IF;

    IF v_source_schema IS NULL THEN
        RAISE EXCEPTION
        'No source schema with patient table found. Set v_source_schema_override.';
    END IF;

    INSERT INTO research_vasopressor_restart_eicu_v1.run_config
    VALUES ('source_schema',v_source_schema,clock_timestamp())
    ON CONFLICT (config_key) DO UPDATE
    SET config_value=EXCLUDED.config_value, updated_at=EXCLUDED.updated_at;
END
$detect$;

CREATE OR REPLACE FUNCTION research_vasopressor_restart_eicu_v1.cfg(p_key text)
RETURNS text LANGUAGE sql STABLE AS $$
SELECT config_value
FROM research_vasopressor_restart_eicu_v1.run_config
WHERE config_key=p_key
$$;

CREATE OR REPLACE FUNCTION research_vasopressor_restart_eicu_v1.actual_table(p_name text)
RETURNS text LANGUAGE sql STABLE AS $$
SELECT table_name
FROM information_schema.tables
WHERE table_schema=research_vasopressor_restart_eicu_v1.cfg('source_schema')
  AND lower(table_name)=lower(p_name)
ORDER BY table_name LIMIT 1
$$;

CREATE OR REPLACE FUNCTION research_vasopressor_restart_eicu_v1.first_col(
    p_table text, p_candidates text[]
)
RETURNS text LANGUAGE sql STABLE AS $$
SELECT c.column_name
FROM unnest(p_candidates) WITH ORDINALITY q(candidate,ord)
JOIN information_schema.columns c
  ON c.table_schema=research_vasopressor_restart_eicu_v1.cfg('source_schema')
 AND lower(c.table_name)=lower(p_table)
 AND lower(c.column_name)=lower(q.candidate)
ORDER BY q.ord LIMIT 1
$$;

CREATE OR REPLACE FUNCTION research_vasopressor_restart_eicu_v1.extract_numeric(p_text text)
RETURNS double precision LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE v text;
BEGIN
    IF p_text IS NULL OR btrim(p_text)='' THEN RETURN NULL; END IF;
    v := substring(replace(p_text,',','') FROM
        '[-+]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][-+]?[0-9]+)?');
    IF v IS NULL THEN RETURN NULL; END IF;
    BEGIN RETURN v::double precision;
    EXCEPTION WHEN others THEN RETURN NULL;
    END;
END
$$;

DROP TABLE IF EXISTS research_vasopressor_restart_eicu_v1.s00_database_info;
CREATE TABLE research_vasopressor_restart_eicu_v1.s00_database_info (
    item text PRIMARY KEY, value text
);
INSERT INTO research_vasopressor_restart_eicu_v1.s00_database_info VALUES
('current_database',current_database()),
('current_user',current_user),
('server_version',current_setting('server_version')),
('server_version_num',current_setting('server_version_num')),
('source_schema',research_vasopressor_restart_eicu_v1.cfg('source_schema')),
('research_schema','research_vasopressor_restart_eicu_v1'),
('run_time',clock_timestamp()::text);

DROP TABLE IF EXISTS research_vasopressor_restart_eicu_v1.s00_schema_inventory;
CREATE TABLE research_vasopressor_restart_eicu_v1.s00_schema_inventory AS
SELECT n.nspname AS schema_name,
       count(c.oid) FILTER (WHERE c.relkind IN ('r','p')) AS tables,
       count(c.oid) FILTER (WHERE c.relkind IN ('v','m')) AS views
FROM pg_namespace n
LEFT JOIN pg_class c ON c.relnamespace=n.oid
WHERE n.nspname NOT LIKE 'pg_toast%'
GROUP BY n.nspname
ORDER BY n.nspname;

DROP TABLE IF EXISTS research_vasopressor_restart_eicu_v1.s00_table_inventory;
CREATE TABLE research_vasopressor_restart_eicu_v1.s00_table_inventory AS
SELECT t.table_name, t.table_type,
       coalesce(s.n_live_tup,0)::bigint AS estimated_rows,
       pg_size_pretty(pg_total_relation_size(
          format('%I.%I',t.table_schema,t.table_name)::regclass
       )) AS total_size
FROM information_schema.tables t
LEFT JOIN pg_stat_user_tables s
  ON s.schemaname=t.table_schema AND s.relname=t.table_name
WHERE t.table_schema=research_vasopressor_restart_eicu_v1.cfg('source_schema')
ORDER BY t.table_name;

DROP TABLE IF EXISTS research_vasopressor_restart_eicu_v1.s00_column_inventory;
CREATE TABLE research_vasopressor_restart_eicu_v1.s00_column_inventory AS
SELECT table_name, ordinal_position, column_name, data_type, udt_name,
       is_nullable, character_maximum_length, numeric_precision, numeric_scale
FROM information_schema.columns
WHERE table_schema=research_vasopressor_restart_eicu_v1.cfg('source_schema')
ORDER BY table_name,ordinal_position;

DROP TABLE IF EXISTS research_vasopressor_restart_eicu_v1.s00_core_table_check;
CREATE TABLE research_vasopressor_restart_eicu_v1.s00_core_table_check AS
WITH required(core_table,relevance) AS (
VALUES
('patient','patient, hospital and ICU-stay identifiers; age; discharge'),
('hospital','center metadata'),
('infusiondrug','continuous vasoactive infusion charting'),
('medication','medication and antimicrobial timing'),
('admissiondrug','admission medication audit'),
('diagnosis','infection/sepsis and comorbidity diagnoses'),
('admissiondx','admission diagnosis'),
('microlab','culture timing and microbiology'),
('lab','SOFA laboratory components and creatinine'),
('vitalperiodic','periodic/invasive MAP candidate'),
('vitalaperiodic','aperiodic/noninvasive MAP candidate'),
('nursecharting','GCS and bedside charting'),
('physicalexam','GCS/neurologic examination'),
('respiratorycharting','FiO2/ventilation candidates'),
('respiratorycare','ventilation episodes'),
('intakeoutput','urine output'),
('treatment','secondary treatment-string audit'),
('apacheapsvar','severity component candidates'),
('apachepatientresult','mortality/outcome descriptors')
)
SELECT r.core_table,
       (t.table_name IS NOT NULL) AS exists_in_source,
       t.table_name AS actual_table_name,
       ti.estimated_rows,
       r.relevance
FROM required r
LEFT JOIN information_schema.tables t
  ON t.table_schema=research_vasopressor_restart_eicu_v1.cfg('source_schema')
 AND lower(t.table_name)=lower(r.core_table)
LEFT JOIN research_vasopressor_restart_eicu_v1.s00_table_inventory ti
  ON ti.table_name=t.table_name
ORDER BY r.core_table;

DROP TABLE IF EXISTS research_vasopressor_restart_eicu_v1.s00_key_time_field_check;
CREATE TABLE research_vasopressor_restart_eicu_v1.s00_key_time_field_check AS
WITH requested(concept,tbl,col,note) AS (
VALUES
('ICU stay identifier','patient','patientunitstayid','required'),
('health-system stay identifier','patient','patienthealthsystemstayid','required'),
('unique patient identifier','patient','uniquepid','required for first stay per patient'),
('hospital identifier','patient','hospitalid','required for center audit'),
('ICU visit sequence','patient','unitvisitnumber','repeat-stay audit'),
('age','patient','age','adult definition and age covariate'),
('ICU discharge offset','patient','unitdischargeoffset','landmark observation'),
('hospital discharge offset','patient','hospitaldischargeoffset','outcome/competing event'),
('ICU discharge status','patient','unitdischargestatus','death/discharge audit'),
('hospital discharge status','patient','hospitaldischargestatus','death/discharge audit'),
('infusion stay identifier','infusiondrug','patientunitstayid','join key'),
('infusion chart offset','infusiondrug','infusionoffset','expected minutes from ICU admission'),
('infusion drug name','infusiondrug','drugname','raw dictionary'),
('infusion drug rate','infusiondrug','drugrate','dose candidate'),
('alternative infusion rate','infusiondrug','infusionrate','dose candidate'),
('infusion patient weight','infusiondrug','patientweight','weight candidate'),
('medication start offset','medication','drugstartoffset','infection/drug timing'),
('medication stop offset','medication','drugstopoffset','infection/drug timing'),
('lab offset','lab','labresultoffset','SOFA timing'),
('periodic vital offset','vitalperiodic','observationoffset','MAP timing'),
('aperiodic vital offset','vitalaperiodic','observationoffset','MAP timing')
)
SELECT r.concept,r.tbl AS candidate_table,r.col AS candidate_column,
       (c.column_name IS NOT NULL) AS exists_in_source,
       t.table_name AS actual_table_name,c.column_name AS actual_column_name,
       c.data_type,r.note
FROM requested r
LEFT JOIN information_schema.tables t
  ON t.table_schema=research_vasopressor_restart_eicu_v1.cfg('source_schema')
 AND lower(t.table_name)=lower(r.tbl)
LEFT JOIN information_schema.columns c
  ON c.table_schema=t.table_schema AND c.table_name=t.table_name
 AND lower(c.column_name)=lower(r.col)
ORDER BY r.concept;

DROP TABLE IF EXISTS research_vasopressor_restart_eicu_v1.s00_primary_key_inventory;
CREATE TABLE research_vasopressor_restart_eicu_v1.s00_primary_key_inventory AS
SELECT tc.table_name,tc.constraint_name,tc.constraint_type,
       kcu.ordinal_position,kcu.column_name
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu
  ON kcu.constraint_name=tc.constraint_name
 AND kcu.table_schema=tc.table_schema AND kcu.table_name=tc.table_name
WHERE tc.table_schema=research_vasopressor_restart_eicu_v1.cfg('source_schema')
  AND tc.constraint_type IN ('PRIMARY KEY','UNIQUE','FOREIGN KEY')
ORDER BY tc.table_name,tc.constraint_type,tc.constraint_name,kcu.ordinal_position;

DROP TABLE IF EXISTS research_vasopressor_restart_eicu_v1.s00_time_like_columns;
CREATE TABLE research_vasopressor_restart_eicu_v1.s00_time_like_columns AS
SELECT table_name,ordinal_position,column_name,data_type,
       CASE WHEN lower(column_name) LIKE '%offset%' THEN 'offset'
            WHEN lower(column_name) LIKE '%time%' THEN 'time'
            WHEN lower(column_name) LIKE '%date%' THEN 'date'
            ELSE 'other' END AS field_type
FROM information_schema.columns
WHERE table_schema=research_vasopressor_restart_eicu_v1.cfg('source_schema')
  AND (lower(column_name) LIKE '%offset%'
    OR lower(column_name) LIKE '%time%'
    OR lower(column_name) LIKE '%date%')
ORDER BY table_name,ordinal_position;

DROP TABLE IF EXISTS research_vasopressor_restart_eicu_v1.s00_patient_icu_relationship;
CREATE TABLE research_vasopressor_restart_eicu_v1.s00_patient_icu_relationship (
    metric text PRIMARY KEY,value_numeric numeric,value_text text,interpretation text
);

DO $patient_qc$
DECLARE
 s text:=research_vasopressor_restart_eicu_v1.cfg('source_schema');
 t text:=research_vasopressor_restart_eicu_v1.actual_table('patient');
 c_stay text:=research_vasopressor_restart_eicu_v1.first_col('patient',ARRAY['patientunitstayid']);
 c_pid text:=research_vasopressor_restart_eicu_v1.first_col('patient',ARRAY['uniquepid']);
 c_hsys text:=research_vasopressor_restart_eicu_v1.first_col('patient',ARRAY['patienthealthsystemstayid']);
 c_hosp text:=research_vasopressor_restart_eicu_v1.first_col('patient',ARRAY['hospitalid']);
 c_ud text:=research_vasopressor_restart_eicu_v1.first_col('patient',ARRAY['unitdischargeoffset']);
 c_hd text:=research_vasopressor_restart_eicu_v1.first_col('patient',ARRAY['hospitaldischargeoffset']);
BEGIN
 IF t IS NULL OR c_stay IS NULL THEN
   INSERT INTO research_vasopressor_restart_eicu_v1.audit_run_log
   (script_name,log_level,message)
   VALUES ('00_eicu_schema_precheck.sql','ERROR','patient or stay ID missing');
   RETURN;
 END IF;

 EXECUTE format(
 'INSERT INTO research_vasopressor_restart_eicu_v1.s00_patient_icu_relationship
  SELECT ''patient_rows'',count(*)::numeric,NULL,''rows in patient table'' FROM %I.%I',
 s,t);

 EXECUTE format(
 'INSERT INTO research_vasopressor_restart_eicu_v1.s00_patient_icu_relationship
  SELECT ''distinct_icu_stays'',count(DISTINCT %I)::numeric,NULL,
  ''distinct patientunitstayid'' FROM %I.%I',c_stay,s,t);

 EXECUTE format(
 'INSERT INTO research_vasopressor_restart_eicu_v1.s00_patient_icu_relationship
  SELECT ''duplicate_stay_rows'',(count(*)-count(DISTINCT %I))::numeric,NULL,
  ''should be zero'' FROM %I.%I',c_stay,s,t);

 IF c_pid IS NOT NULL THEN
   EXECUTE format(
   'INSERT INTO research_vasopressor_restart_eicu_v1.s00_patient_icu_relationship
    SELECT ''distinct_patients'',count(DISTINCT %I)::numeric,NULL,
    ''distinct uniquepid'' FROM %I.%I',c_pid,s,t);
   EXECUTE format(
   'INSERT INTO research_vasopressor_restart_eicu_v1.s00_patient_icu_relationship
    SELECT ''patients_with_multiple_icu_stays'',count(*)::numeric,NULL,
    ''patients with >1 stay''
    FROM (SELECT %I FROM %I.%I WHERE %I IS NOT NULL
          GROUP BY %I HAVING count(DISTINCT %I)>1)x',
    c_pid,s,t,c_pid,c_pid,c_stay);
 END IF;

 IF c_hsys IS NOT NULL THEN
   EXECUTE format(
   'INSERT INTO research_vasopressor_restart_eicu_v1.s00_patient_icu_relationship
    SELECT ''distinct_healthsystem_stays'',count(DISTINCT %I)::numeric,NULL,
    ''hospitalizations'' FROM %I.%I',c_hsys,s,t);
 END IF;

 IF c_hosp IS NOT NULL THEN
   EXECUTE format(
   'INSERT INTO research_vasopressor_restart_eicu_v1.s00_patient_icu_relationship
    SELECT ''distinct_hospitals'',count(DISTINCT %I)::numeric,NULL,
    ''centers'' FROM %I.%I',c_hosp,s,t);
 END IF;

 IF c_ud IS NOT NULL THEN
   EXECUTE format(
   'INSERT INTO research_vasopressor_restart_eicu_v1.s00_patient_icu_relationship
    SELECT ''unitdischargeoffset_nonpositive'',
    count(*) FILTER (WHERE research_vasopressor_restart_eicu_v1.extract_numeric(%I::text)<=0)::numeric,
    NULL,''invalid ICU duration'' FROM %I.%I',c_ud,s,t);
 END IF;

 IF c_ud IS NOT NULL AND c_hd IS NOT NULL THEN
   EXECUTE format(
   'INSERT INTO research_vasopressor_restart_eicu_v1.s00_patient_icu_relationship
    SELECT ''hospital_discharge_before_icu_discharge'',
    count(*) FILTER (WHERE
      research_vasopressor_restart_eicu_v1.extract_numeric(%I::text) <
      research_vasopressor_restart_eicu_v1.extract_numeric(%I::text))::numeric,
    NULL,''offset inconsistency'' FROM %I.%I',c_hd,c_ud,s,t);
 END IF;
EXCEPTION WHEN others THEN
 INSERT INTO research_vasopressor_restart_eicu_v1.audit_run_log
 (script_name,log_level,message)
 VALUES ('00_eicu_schema_precheck.sql','ERROR',SQLERRM);
END
$patient_qc$;

INSERT INTO research_vasopressor_restart_eicu_v1.audit_run_log
(script_name,log_level,message)
VALUES ('00_eicu_schema_precheck.sql','INFO','Completed');

SELECT * FROM research_vasopressor_restart_eicu_v1.s00_database_info ORDER BY item;
SELECT * FROM research_vasopressor_restart_eicu_v1.s00_core_table_check ORDER BY core_table;
SELECT * FROM research_vasopressor_restart_eicu_v1.s00_patient_icu_relationship ORDER BY metric;
SELECT * FROM research_vasopressor_restart_eicu_v1.s00_key_time_field_check
WHERE NOT exists_in_source ORDER BY concept;
