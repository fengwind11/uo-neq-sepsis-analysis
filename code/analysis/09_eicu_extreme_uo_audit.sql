\set ON_ERROR_STOP on
SET statement_timeout='300s';
BEGIN;
CREATE TEMP TABLE x(analysis_row bigint,stay_id int,t0 int,weight_kg double precision,
                    urine_ml_6h double precision,uo_ml_kg_h double precision);
\copy x FROM 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/PRIVATE_WORK/eicu_extreme_anchor.csv' CSV HEADER
CREATE TEMP TABLE raw AS
SELECT x.analysis_row,x.stay_id,x.t0,x.weight_kg,x.urine_ml_6h,x.uo_ml_kg_h,
       io.intakeoutputid,io.intakeoutputoffset,io.intakeoutputentryoffset,
       io.cellpath,io.celllabel,io.cellvaluenumeric,io.cellvaluetext,
       io.intaketotal,io.outputtotal,io.nettotal,
       count(*) OVER(PARTITION BY x.stay_id,io.intakeoutputoffset) AS raw_rows_same_offset
FROM x JOIN eicu_crd.intakeoutput io ON io.patientunitstayid=x.stay_id
  AND io.intakeoutputoffset>=x.t0 AND io.intakeoutputoffset<x.t0+360
WHERE lower(btrim(io.celllabel)) !~ '(mixed urine/stool|count|occurrence|incontinen|unmeasured)'
  AND (lower(btrim(io.celllabel)) IN ('urine','urine catheter','voided amount','sn urine output(ml)',
       'foley','foley cath','urine output-foley','urostomy','nephrostomy output',
       'suprapubic urine output','or urine')
       OR lower(btrim(io.celllabel)) LIKE 'urinary catheter output:%'
       OR lower(btrim(io.celllabel)) LIKE 'output (ml)-urinary catheter%'
       OR lower(btrim(io.celllabel)) LIKE 'output (ml)-external urinary catheter%'
       OR lower(btrim(io.celllabel)) LIKE 'urine output (ml)-urethral catheter%'
       OR lower(btrim(io.celllabel)) LIKE 'output (ml)-nephrostomy%'
       OR lower(btrim(io.celllabel)) LIKE '%nephrostomy%output%'
       OR lower(btrim(io.celllabel)) LIKE 'output amt-urinary catheter%'
       OR lower(btrim(io.celllabel)) LIKE 'urine, void:%');
SELECT * FROM raw ORDER BY analysis_row,intakeoutputoffset,intakeoutputid
\g (format=csv) 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/PRIVATE_WORK/eicu_extreme_uo_raw_30.csv'
WITH t AS (SELECT analysis_row,intakeoutputoffset,max(cellvaluenumeric) AS contribution_ml,
                  count(*) AS rows_same_offset
           FROM raw WHERE cellvaluenumeric BETWEEN 0 AND 5000 GROUP BY 1,2)
SELECT x.analysis_row,x.weight_kg,x.urine_ml_6h,x.uo_ml_kg_h,count(t.intakeoutputoffset) AS timepoints,
       sum(t.contribution_ml) AS source_recomputed_ml,
       count(*) FILTER(WHERE t.rows_same_offset>1) AS duplicate_offset_n,
       max(t.contribution_ml) AS largest_single_timepoint_ml
FROM x LEFT JOIN t USING(analysis_row) GROUP BY 1,2,3,4 ORDER BY x.uo_ml_kg_h DESC
\g (format=csv) 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/CORRECTED_MANUSCRIPT_RESULTS_v1_1/01_SOURCE_LINEAGE/eicu_extreme_uo_source_summary.csv'
ROLLBACK;
