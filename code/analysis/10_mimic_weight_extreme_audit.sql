\set ON_ERROR_STOP on
SET statement_timeout='120s';
BEGIN;
CREATE TEMP TABLE x(analysis_row bigint,stay_id int,t0 timestamp,weight_kg double precision,
                    urine_ml_6h double precision,uo_ml_kg_h double precision,hadm_id int);
\copy x FROM 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/PRIVATE_WORK/mimic_source_anchor.csv' CSV HEADER
SELECT x.analysis_row,x.weight_kg AS selected_weight,x.t0,
       c.charttime,c.itemid,d.label,c.valuenum,c.valueuom,
       wd.starttime,wd.endtime,wd.weight AS duration_weight,wd.weight_type
FROM x JOIN mimiciv_icu.chartevents c ON c.stay_id=x.stay_id
  AND c.itemid IN (226512,224639)
JOIN mimiciv_icu.d_items d ON d.itemid=c.itemid
LEFT JOIN mimiciv_derived.weight_durations wd ON wd.stay_id=x.stay_id
  AND wd.starttime<=x.t0 AND wd.endtime>x.t0
WHERE x.weight_kg<20
ORDER BY c.charttime
\g (format=csv) 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/PRIVATE_WORK/mimic_weight_extreme_case.csv'
ROLLBACK;
