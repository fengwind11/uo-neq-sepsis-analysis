\set ON_ERROR_STOP on
\pset pager off
\timing on

-- eICU Stage-0 feasibility audit for UO/NEQ.
-- This is an outcome-blind data gate. It does not run formal outcome models.
-- eICU infusionOffset is an entry offset, not a verified start/stop timestamp.
-- T0 confirmation requires the immediate next same-agent usable dose record with
-- a strictly positive gap <=240 minutes. Confirmation ends at that next offset;
-- no terminal carry and no artificial extension to the 240-minute cap are allowed.
-- The separate T0-T0+6h exposure uses outcome-blind capped interval weighting.

BEGIN;
SET LOCAL statement_timeout = '900s';
SET LOCAL lock_timeout = '5s';

CREATE TEMP TABLE e_base ON COMMIT DROP AS
SELECT s.*
FROM research_vasopressor_restart_eicu_v1.e05_sepsis_cohort s
WHERE s.age >= 18
  AND s.rn = 1
  AND s.sepsis_sofa >= 2
  AND s.unitdischargeoffset > 0;
CREATE UNIQUE INDEX ON e_base(patientunitstayid);
ANALYZE e_base;

CREATE TEMP TABLE e_dose_at_time ON COMMIT DROP AS
SELECT n.patientunitstayid,
       n.agent,
       n.infusionoffset,
       max(n.ne_eq_rate) FILTER (WHERE n.usable_positive_record = 1) AS dose_neq,
       bool_or(n.explicit_zero = 1) AS has_explicit_zero,
       bool_or(n.exclusion_reason IS NOT NULL AND coalesce(n.rate_num, 0) > 0) AS has_unusable_positive,
       count(*) AS source_rows,
       count(*) FILTER (WHERE n.usable_positive_record = 1) AS usable_rows,
       count(DISTINCT n.ne_eq_rate) FILTER (WHERE n.usable_positive_record = 1) AS distinct_positive_doses
FROM research_uo_neq_eicu_repair_v1.pressor_normalized_rows n
JOIN e_base b USING (patientunitstayid)
GROUP BY n.patientunitstayid, n.agent, n.infusionoffset;
CREATE INDEX ON e_dose_at_time(patientunitstayid, agent, infusionoffset);
ANALYZE e_dose_at_time;

CREATE TEMP TABLE e_dose_seq ON COMMIT DROP AS
SELECT d.*,
       ((d.has_explicit_zero AND d.dose_neq > 0) OR d.distinct_positive_doses > 1) AS same_offset_dose_conflict,
       lead(d.infusionoffset) OVER (
         PARTITION BY d.patientunitstayid, d.agent
         ORDER BY d.infusionoffset
       ) AS next_offset,
       lead((d.usable_rows > 0 OR d.has_explicit_zero)
            AND NOT d.has_unusable_positive
            AND NOT ((d.has_explicit_zero AND d.dose_neq > 0) OR d.distinct_positive_doses > 1)) OVER (
         PARTITION BY d.patientunitstayid, d.agent
         ORDER BY d.infusionoffset
       ) AS next_state_usable,
       b.unitdischargeoffset
FROM e_dose_at_time d
JOIN e_base b USING (patientunitstayid);
CREATE INDEX ON e_dose_seq(patientunitstayid, infusionoffset);
ANALYZE e_dose_seq;

CREATE TEMP TABLE e_intervals ON COMMIT DROP AS
WITH variants(variant_name, cap_min, terminal_carry) AS (
  VALUES ('cap60'::text, 60, true),
         ('cap240'::text, 240, true),
         ('cap360'::text, 360, true),
         ('no_terminal_cap240'::text, 240, false)
), x AS (
  SELECT d.patientunitstayid, d.agent, d.infusionoffset AS start_offset,
         d.dose_neq, v.variant_name,
         CASE
           WHEN v.terminal_carry THEN
             least(coalesce(d.next_offset, d.infusionoffset + v.cap_min),
                   d.infusionoffset + v.cap_min, d.unitdischargeoffset)
           WHEN d.next_offset IS NOT NULL
             AND d.next_state_usable
             AND d.next_offset - d.infusionoffset > 0
             AND d.next_offset - d.infusionoffset <= 240
           THEN least(d.next_offset, d.unitdischargeoffset)
           ELSE d.infusionoffset
         END AS end_offset
  FROM e_dose_seq d
  CROSS JOIN variants v
  WHERE d.dose_neq > 0
    AND NOT d.has_unusable_positive
    AND NOT d.same_offset_dose_conflict
)
SELECT *
FROM x
WHERE end_offset > start_offset;
CREATE INDEX ON e_intervals(variant_name, patientunitstayid, start_offset, end_offset);
ANALYZE e_intervals;

-- Fixed T0 confirmation: every contributing agent interval has a usable next
-- same-agent record within 240 minutes, and end_offset is exactly next_offset.
CREATE TEMP TABLE e_confirm_episodes ON COMMIT DROP AS
WITH i1 AS (
  SELECT i.*,
         max(i.end_offset) OVER (
           PARTITION BY i.patientunitstayid
           ORDER BY i.start_offset, i.end_offset
           ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
         ) AS prior_max_end
  FROM e_intervals i
  WHERE i.variant_name = 'no_terminal_cap240'
), i2 AS (
  SELECT i1.*,
         sum(CASE WHEN prior_max_end IS NULL OR start_offset > prior_max_end THEN 1 ELSE 0 END)
           OVER (PARTITION BY patientunitstayid ORDER BY start_offset, end_offset) AS episode_id
  FROM i1
)
SELECT patientunitstayid, episode_id,
       min(start_offset) AS episode_start,
       max(end_offset) AS episode_end
FROM i2
GROUP BY patientunitstayid, episode_id;
CREATE INDEX ON e_confirm_episodes(patientunitstayid, episode_start, episode_end);

CREATE TEMP TABLE e_t0_30 ON COMMIT DROP AS
SELECT patientunitstayid, min(episode_start) AS t0_30
FROM e_confirm_episodes
WHERE episode_start >= 0
  AND episode_end - episode_start >= 30
GROUP BY patientunitstayid;
CREATE UNIQUE INDEX ON e_t0_30(patientunitstayid);

CREATE TEMP TABLE e_t0 ON COMMIT DROP AS
SELECT patientunitstayid, min(episode_start) AS t0
FROM e_confirm_episodes
WHERE episode_start >= 0
  AND episode_end - episode_start >= 60
GROUP BY patientunitstayid;
CREATE UNIQUE INDEX ON e_t0(patientunitstayid);
ANALYZE e_t0;

-- Reconstruct the pre-repair implementation on the same source-normalized rows.
-- This audit branch is descriptive only and cannot set the repaired T0.
CREATE TEMP TABLE e_old_confirm_intervals ON COMMIT DROP AS
SELECT d.patientunitstayid, d.agent, d.infusionoffset AS start_offset,
       least(d.next_offset, d.infusionoffset + 240, d.unitdischargeoffset) AS end_offset
FROM e_dose_seq d
WHERE d.dose_neq > 0
  AND NOT d.has_unusable_positive
  AND NOT (d.has_explicit_zero AND d.dose_neq > 0)
  AND d.next_offset IS NOT NULL
  AND d.next_offset > d.infusionoffset;
CREATE INDEX ON e_old_confirm_intervals(patientunitstayid,start_offset,end_offset);

CREATE TEMP TABLE e_old_confirm_episodes ON COMMIT DROP AS
WITH i1 AS (
  SELECT i.*,
         max(i.end_offset) OVER (
           PARTITION BY i.patientunitstayid
           ORDER BY i.start_offset,i.end_offset
           ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
         ) AS prior_max_end
  FROM e_old_confirm_intervals i
), i2 AS (
  SELECT i1.*,
         sum(CASE WHEN prior_max_end IS NULL OR start_offset > prior_max_end THEN 1 ELSE 0 END)
           OVER (PARTITION BY patientunitstayid ORDER BY start_offset,end_offset) AS episode_id
  FROM i1
)
SELECT patientunitstayid,episode_id,min(start_offset) AS episode_start,max(end_offset) AS episode_end
FROM i2 GROUP BY patientunitstayid,episode_id;

CREATE TEMP TABLE e_old_t0 ON COMMIT DROP AS
SELECT patientunitstayid,min(episode_start) AS old_t0
FROM e_old_confirm_episodes
WHERE episode_start >= 0 AND episode_end-episode_start >= 60
GROUP BY patientunitstayid;
CREATE UNIQUE INDEX ON e_old_t0(patientunitstayid);

CREATE TEMP TABLE e_t0_gap_audit ON COMMIT DROP AS
WITH c AS (
  SELECT patientunitstayid,agent,infusionoffset,next_offset,
         next_offset-infusionoffset AS gap_min
  FROM e_dose_seq
  WHERE dose_neq > 0
    AND NOT has_unusable_positive
    AND NOT same_offset_dose_conflict
), b AS (
  SELECT *,CASE
    WHEN gap_min BETWEEN 1 AND 60 THEN '<=60'
    WHEN gap_min BETWEEN 61 AND 120 THEN '61-120'
    WHEN gap_min BETWEEN 121 AND 240 THEN '121-240'
    WHEN gap_min > 240 THEN '>240'
    WHEN next_offset IS NULL THEN 'terminal_no_next'
    ELSE 'nonpositive_or_invalid'
  END AS gap_bin
  FROM c
)
SELECT gap_bin,count(*) AS candidate_rows,count(DISTINCT patientunitstayid) AS stays,
       round(100.0*count(*)/sum(count(*)) OVER (),4) AS percent_rows,
       min(gap_min) AS min_gap,percentile_cont(0.5) WITHIN GROUP (ORDER BY gap_min) AS median_gap,
       max(gap_min) AS max_gap
FROM b GROUP BY gap_bin
ORDER BY CASE gap_bin WHEN '<=60' THEN 1 WHEN '61-120' THEN 2 WHEN '121-240' THEN 3 WHEN '>240' THEN 4 WHEN 'terminal_no_next' THEN 5 ELSE 6 END;

CREATE TEMP TABLE e_old_vs_fixed_t0 ON COMMIT DROP AS
WITH z AS (
  SELECT coalesce(o.patientunitstayid,f.patientunitstayid) AS patientunitstayid,
         o.old_t0,f.t0 AS fixed_t0,(f.t0-o.old_t0) AS shift_min
  FROM e_old_t0 o FULL JOIN e_t0 f USING(patientunitstayid)
)
SELECT count(*) FILTER (WHERE old_t0 IS NOT NULL) AS old_t0_n,
       count(*) FILTER (WHERE fixed_t0 IS NOT NULL) AS fixed_t0_n,
       count(*) FILTER (WHERE old_t0 IS NOT NULL AND fixed_t0 IS NOT NULL) AS both_n,
       count(*) FILTER (WHERE old_t0 IS NOT NULL AND fixed_t0 IS NULL) AS old_only_n,
       count(*) FILTER (WHERE old_t0 IS NULL AND fixed_t0 IS NOT NULL) AS fixed_only_n,
       round(100.0*count(*) FILTER (WHERE old_t0=fixed_t0)/nullif(count(*) FILTER (WHERE old_t0 IS NOT NULL AND fixed_t0 IS NOT NULL),0),4) AS exact_t0_overlap_percent_among_both,
       percentile_cont(0.25) WITHIN GROUP (ORDER BY shift_min) FILTER (WHERE shift_min IS NOT NULL) AS shift_q1_min,
       percentile_cont(0.50) WITHIN GROUP (ORDER BY shift_min) FILTER (WHERE shift_min IS NOT NULL) AS shift_median_min,
       percentile_cont(0.75) WITHIN GROUP (ORDER BY shift_min) FILTER (WHERE shift_min IS NOT NULL) AS shift_q3_min,
       round(100.0*count(*) FILTER (WHERE abs(shift_min)>60)/nullif(count(*) FILTER (WHERE shift_min IS NOT NULL),0),4) AS abs_shift_gt60_percent,
       round(100.0*count(*) FILTER (WHERE abs(shift_min)>240)/nullif(count(*) FILTER (WHERE shift_min IS NOT NULL),0),4) AS abs_shift_gt240_percent
FROM z;
CREATE TEMP TABLE e_landmark ON COMMIT DROP AS
SELECT b.*, t.t0,
       CASE WHEN b.admissionweight BETWEEN 20 AND 300
            THEN b.admissionweight::double precision END AS weight_kg
FROM e_base b
JOIN e_t0 t USING (patientunitstayid)
WHERE b.unitdischargeoffset >= t.t0 + 360;
CREATE UNIQUE INDEX ON e_landmark(patientunitstayid);
ANALYZE e_landmark;

CREATE TEMP TABLE e_variant_episodes ON COMMIT DROP AS
WITH i1 AS (
  SELECT i.*,
         max(i.end_offset) OVER (
           PARTITION BY i.variant_name, i.patientunitstayid
           ORDER BY i.start_offset, i.end_offset
           ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
         ) AS prior_max_end
  FROM e_intervals i
), i2 AS (
  SELECT i1.*,
         sum(CASE WHEN prior_max_end IS NULL OR start_offset > prior_max_end THEN 1 ELSE 0 END)
           OVER (PARTITION BY variant_name, patientunitstayid ORDER BY start_offset, end_offset) AS episode_id
  FROM i1
)
SELECT variant_name, patientunitstayid, episode_id,
       min(start_offset) AS episode_start,
       max(end_offset) AS episode_end
FROM i2
GROUP BY variant_name, patientunitstayid, episode_id;
CREATE INDEX ON e_variant_episodes(variant_name, patientunitstayid, episode_start, episode_end);

CREATE TEMP TABLE e_variant_twa ON COMMIT DROP AS
WITH area AS (
  SELECT l.patientunitstayid, i.variant_name,
         sum(i.dose_neq * greatest(0, least(i.end_offset, l.t0 + 360) - greatest(i.start_offset, l.t0))) / 360.0 AS twa_neq,
         count(DISTINCT i.agent) AS active_agents,
         bool_or(i.agent = 'vasopressin') AS vasopressin_used
  FROM e_landmark l
  JOIN e_intervals i
    ON i.patientunitstayid = l.patientunitstayid
   AND i.start_offset < l.t0 + 360
   AND i.end_offset > l.t0
  GROUP BY l.patientunitstayid, i.variant_name
), coverage AS (
  SELECT l.patientunitstayid, e.variant_name,
         sum(greatest(0, least(e.episode_end, l.t0 + 360) - greatest(e.episode_start, l.t0))) AS active_minutes,
         bool_or(e.episode_start <= l.t0 AND e.episode_end >= l.t0 + 60) AS supports_first_60min
  FROM e_landmark l
  JOIN e_variant_episodes e
    ON e.patientunitstayid = l.patientunitstayid
   AND e.episode_start < l.t0 + 360
   AND e.episode_end > l.t0
  GROUP BY l.patientunitstayid, e.variant_name
)
SELECT a.*, c.active_minutes, c.supports_first_60min
FROM area a
JOIN coverage c USING (patientunitstayid, variant_name);
CREATE UNIQUE INDEX ON e_variant_twa(patientunitstayid, variant_name);
ANALYZE e_variant_twa;

CREATE TEMP TABLE e_pressor_qc ON COMMIT DROP AS
SELECT l.patientunitstayid,
       bool_or(d.has_unusable_positive OR d.same_offset_dose_conflict)
         FILTER (WHERE d.infusionoffset >= l.t0 AND d.infusionoffset < l.t0 + 360) AS any_unusable_or_conflicting_positive_0_6h,
       count(*) FILTER (
         WHERE d.infusionoffset >= l.t0 AND d.infusionoffset < l.t0 + 360
           AND d.source_rows > 1
       ) AS duplicate_agent_time_points
FROM e_landmark l
LEFT JOIN e_dose_seq d USING (patientunitstayid)
GROUP BY l.patientunitstayid;
CREATE UNIQUE INDEX ON e_pressor_qc(patientunitstayid);

CREATE TEMP TABLE e_uo_raw ON COMMIT DROP AS
SELECT l.patientunitstayid, i.intakeoutputid, i.intakeoutputoffset,
       lower(btrim(i.celllabel)) AS celllabel,
       i.cellpath, i.intakeoutputentryoffset,
       i.cellvaluenumeric::double precision AS urine_ml
FROM e_landmark l
JOIN eicu_crd.intakeoutput i
  ON i.patientunitstayid = l.patientunitstayid
 AND i.intakeoutputoffset >= l.t0
 AND i.intakeoutputoffset < l.t0 + 360
WHERE lower(btrim(i.celllabel)) !~ '(mixed urine/stool|count|occurrence|incontinen|unmeasured)'
  AND (
    lower(btrim(i.celllabel)) IN (
      'urine','urine catheter','voided amount','sn urine output(ml)',
      'foley','foley cath','urine output-foley','urostomy',
      'nephrostomy output','suprapubic urine output','or urine'
    )
    OR lower(btrim(i.celllabel)) LIKE 'urinary catheter output:%'
    OR lower(btrim(i.celllabel)) LIKE 'output (ml)-urinary catheter%'
    OR lower(btrim(i.celllabel)) LIKE 'output (ml)-external urinary catheter%'
    OR lower(btrim(i.celllabel)) LIKE 'urine output (ml)-urethral catheter%'
    OR lower(btrim(i.celllabel)) LIKE 'output (ml)-nephrostomy%'
    OR lower(btrim(i.celllabel)) LIKE '%nephrostomy%output%'
    OR lower(btrim(i.celllabel)) LIKE 'output amt-urinary catheter%'
    OR lower(btrim(i.celllabel)) LIKE 'urine, void:%'
  );
CREATE INDEX ON e_uo_raw(patientunitstayid, intakeoutputoffset);
ANALYZE e_uo_raw;

CREATE TEMP TABLE e_uo_event ON COMMIT DROP AS
SELECT patientunitstayid, intakeoutputoffset,
       max(urine_ml) AS urine_ml,
       count(*) AS source_rows_same_offset,
       max(intakeoutputentryoffset - intakeoutputoffset) AS max_entry_lag_min
FROM e_uo_raw
WHERE urine_ml BETWEEN 0 AND 5000
GROUP BY patientunitstayid, intakeoutputoffset;
CREATE UNIQUE INDEX ON e_uo_event(patientunitstayid, intakeoutputoffset);

CREATE TEMP TABLE e_uo_summary ON COMMIT DROP AS
SELECT l.patientunitstayid,
       count(u.intakeoutputoffset) AS uo_timepoints,
       count(DISTINCT floor((u.intakeoutputoffset - l.t0) / 60.0)) AS uo_observed_hours,
       sum(u.urine_ml) AS urine_ml_6h,
       sum(u.urine_ml) / nullif(l.weight_kg * 6.0, 0) AS uo_ml_kg_h,
       count(*) FILTER (WHERE u.urine_ml = 0) AS zero_timepoints,
       count(*) FILTER (WHERE u.source_rows_same_offset > 1) AS duplicated_timepoints,
       max(u.urine_ml) AS max_single_timepoint_ml,
       min(u.intakeoutputoffset - l.t0) AS first_uo_min_from_t0,
       max(u.max_entry_lag_min) AS max_entry_lag_min
FROM e_landmark l
LEFT JOIN e_uo_event u USING (patientunitstayid)
GROUP BY l.patientunitstayid, l.weight_kg;
CREATE UNIQUE INDEX ON e_uo_summary(patientunitstayid);
ANALYZE e_uo_summary;

CREATE TEMP TABLE e_chronic_dialysis ON COMMIT DROP AS
SELECT d.patientunitstayid
FROM e_landmark l
JOIN eicu_crd.diagnosis d USING (patientunitstayid)
WHERE lower(coalesce(d.diagnosisstring, '')) LIKE '%esrd (end stage renal disease)%'
UNION
SELECT t.patientunitstayid
FROM e_landmark l
JOIN eicu_crd.treatment t USING (patientunitstayid)
WHERE lower(coalesce(t.treatmentstring, '')) LIKE '%dialysis%for chronic renal failure%';
CREATE UNIQUE INDEX ON e_chronic_dialysis(patientunitstayid);

CREATE TEMP TABLE e_krt_event ON COMMIT DROP AS
SELECT t.patientunitstayid, t.treatmentoffset
FROM e_landmark l
JOIN eicu_crd.treatment t USING (patientunitstayid)
WHERE lower(btrim(t.treatmentstring)) ~
      '^renal\|dialysis\|(hemodialysis|c v v h d|c v v h|c a v h d|peritoneal dialysis|ultrafiltration)';
CREATE INDEX ON e_krt_event(patientunitstayid, treatmentoffset);

-- Medication rows are orders, not verified administrations. These flags are
-- deliberately labelled proxies. Infusion rows are chart-entry records.
CREATE TEMP TABLE e_loop_flags ON COMMIT DROP AS
WITH med AS (
  SELECT l.patientunitstayid,
         coalesce(nullif(m.drugstartoffset, 0), m.drugorderoffset) AS start_offset,
         CASE
           WHEN m.drugstopoffset IS NOT NULL
             AND m.drugstopoffset >= coalesce(nullif(m.drugstartoffset, 0), m.drugorderoffset)
           THEN m.drugstopoffset
           ELSE coalesce(nullif(m.drugstartoffset, 0), m.drugorderoffset)
         END AS stop_offset
  FROM e_landmark l
  JOIN eicu_crd.medication m USING (patientunitstayid)
  WHERE lower(coalesce(m.drugname, '')) ~ '(furosemide|lasix|bumetanide|bumex|torsemide|demadex)'
    AND lower(btrim(coalesce(m.drugordercancelled, ''))) = 'no'
), inf AS (
  SELECT l.patientunitstayid, i.infusionoffset AS event_offset
  FROM e_landmark l
  JOIN eicu_crd.infusiondrug i USING (patientunitstayid)
  WHERE lower(coalesce(i.drugname, '')) ~ '(furosemide|lasix|bumetanide|bumex|torsemide|demadex)'
    AND btrim(coalesce(i.drugrate, '')) ~ '^[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)$'
    AND btrim(i.drugrate)::double precision > 0
)
SELECT l.patientunitstayid,
       EXISTS (SELECT 1 FROM med m WHERE m.patientunitstayid=l.patientunitstayid
               AND m.start_offset < l.t0 AND m.stop_offset >= l.t0 - 360)
       OR EXISTS (SELECT 1 FROM inf i WHERE i.patientunitstayid=l.patientunitstayid
                  AND i.event_offset >= l.t0 - 360 AND i.event_offset < l.t0) AS loop_pre6h_proxy,
       EXISTS (SELECT 1 FROM med m WHERE m.patientunitstayid=l.patientunitstayid
               AND m.start_offset < l.t0 + 360 AND m.stop_offset >= l.t0)
       OR EXISTS (SELECT 1 FROM inf i WHERE i.patientunitstayid=l.patientunitstayid
                  AND i.event_offset >= l.t0 AND i.event_offset < l.t0 + 360) AS loop_0_6h_proxy,
       EXISTS (SELECT 1 FROM med m WHERE m.patientunitstayid=l.patientunitstayid
               AND m.start_offset < l.t0 + 1440 AND m.stop_offset >= l.t0 + 360)
       OR EXISTS (SELECT 1 FROM inf i WHERE i.patientunitstayid=l.patientunitstayid
                  AND i.event_offset >= l.t0 + 360 AND i.event_offset < l.t0 + 1440) AS loop_6_24h_proxy
FROM e_landmark l;
CREATE UNIQUE INDEX ON e_loop_flags(patientunitstayid);

CREATE TEMP TABLE e_status ON COMMIT DROP AS
SELECT b.patientunitstayid, b.hospitalid, b.age, b.t0, b.unitdischargeoffset,
       b.hospitaldischargeoffset, b.hospitaldischargestatus, b.weight_kg,
       u.uo_timepoints, u.uo_observed_hours, u.urine_ml_6h, u.uo_ml_kg_h,
       u.zero_timepoints, u.duplicated_timepoints, u.max_single_timepoint_ml,
       u.first_uo_min_from_t0, u.max_entry_lag_min,
       v.twa_neq, v.active_minutes, v.active_agents, v.vasopressin_used,
       coalesce(q.any_unusable_or_conflicting_positive_0_6h, false) AS pressor_unit_or_conflict_problem,
       (cd.patientunitstayid IS NOT NULL) AS chronic_dialysis_or_esrd,
       EXISTS (SELECT 1 FROM e_krt_event k WHERE k.patientunitstayid=b.patientunitstayid AND k.treatmentoffset <= b.t0) AS prior_krt,
       EXISTS (SELECT 1 FROM e_krt_event k WHERE k.patientunitstayid=b.patientunitstayid AND k.treatmentoffset > b.t0 AND k.treatmentoffset < b.t0+360) AS krt_0_6h,
       EXISTS (SELECT 1 FROM e_krt_event k WHERE k.patientunitstayid=b.patientunitstayid AND k.treatmentoffset >= b.t0+360 AND k.treatmentoffset < b.t0+1440) AS krt_6_24h,
       f.loop_pre6h_proxy, f.loop_0_6h_proxy, f.loop_6_24h_proxy,
       CASE
         WHEN lower(coalesce(b.hospitaldischargestatus,'')) = 'expired'
          AND b.hospitaldischargeoffset > b.t0 + 360
          AND b.hospitaldischargeoffset <= b.t0 + 40320 THEN 1
         WHEN lower(coalesce(b.hospitaldischargestatus,'')) IN ('alive','expired') THEN 0
       END AS death_28d_inhospital,
       0.1 * u.uo_ml_kg_h / nullif(v.twa_neq, 0) AS scaled_uo_neq
FROM e_landmark b
LEFT JOIN e_uo_summary u USING (patientunitstayid)
LEFT JOIN e_variant_twa v
  ON v.patientunitstayid=b.patientunitstayid AND v.variant_name='cap240'
LEFT JOIN e_pressor_qc q ON q.patientunitstayid=b.patientunitstayid
LEFT JOIN e_chronic_dialysis cd ON cd.patientunitstayid=b.patientunitstayid
JOIN e_loop_flags f ON f.patientunitstayid=b.patientunitstayid;
CREATE UNIQUE INDEX ON e_status(patientunitstayid);
ANALYZE e_status;

CREATE TEMP TABLE e_gate_status ON COMMIT DROP AS
SELECT s.*,
       (s.weight_kg IS NOT NULL) AS valid_weight,
       (s.uo_timepoints > 0 AND s.urine_ml_6h IS NOT NULL) AS uo_reconstructable,
       (s.twa_neq > 0 AND NOT s.pressor_unit_or_conflict_problem) AS twa_reconstructable,
       (s.weight_kg IS NOT NULL
        AND s.uo_timepoints > 0 AND s.urine_ml_6h IS NOT NULL
        AND s.twa_neq > 0 AND NOT s.pressor_unit_or_conflict_problem
        AND NOT s.chronic_dialysis_or_esrd AND NOT s.prior_krt AND NOT s.krt_0_6h) AS ratio_ready,
       (s.weight_kg IS NOT NULL
        AND s.uo_timepoints > 0 AND s.urine_ml_6h IS NOT NULL
        AND s.twa_neq > 0 AND NOT s.pressor_unit_or_conflict_problem
        AND NOT s.chronic_dialysis_or_esrd AND NOT s.prior_krt AND NOT s.krt_0_6h
        AND NOT s.loop_0_6h_proxy) AS clean_ratio_ready
FROM e_status s;
CREATE UNIQUE INDEX ON e_gate_status(patientunitstayid);
ANALYZE e_gate_status;

CREATE TEMP TABLE e_cohort_flow ON COMMIT DROP AS
SELECT * FROM (
  SELECT 0 AS step, 'adult_first_validated_sepsis3_stay'::text AS criterion, count(*)::bigint AS n, NULL::bigint AS deaths FROM e_base
  UNION ALL SELECT 1, 'any_convertible_positive_vasopressor_record', count(DISTINCT patientunitstayid), NULL FROM e_intervals
  UNION ALL SELECT 2, 'sustained_pressor_T0_30min_sensitivity', count(*), NULL FROM e_t0_30
  UNION ALL SELECT 3, 'sustained_pressor_T0_60min_primary', count(*), NULL FROM e_t0
  UNION ALL SELECT 4, 'death_T0_0_6h_reported_separately', count(*), count(*) FROM e_base b JOIN e_t0 t USING(patientunitstayid) WHERE lower(coalesce(b.hospitaldischargestatus,''))='expired' AND b.hospitaldischargeoffset>=t.t0 AND b.hospitaldischargeoffset<t.t0+360
  UNION ALL SELECT 5, 'observable_through_T0_plus_6h', count(*), NULL FROM e_landmark
  UNION ALL SELECT 6, 'plus_valid_admission_weight_20_to_300kg', count(*), NULL FROM e_gate_status WHERE valid_weight
  UNION ALL SELECT 7, 'plus_UO_reconstructable', count(*), NULL FROM e_gate_status WHERE valid_weight AND uo_reconstructable
  UNION ALL SELECT 8, 'plus_TWA_NEQ_reconstructable', count(*), NULL FROM e_gate_status WHERE valid_weight AND uo_reconstructable AND twa_reconstructable
  UNION ALL SELECT 9, 'plus_no_chronic_dialysis_or_ESRD', count(*), NULL FROM e_gate_status WHERE valid_weight AND uo_reconstructable AND twa_reconstructable AND NOT chronic_dialysis_or_esrd
  UNION ALL SELECT 10, 'plus_no_KRT_at_or_before_T0', count(*), NULL FROM e_gate_status WHERE valid_weight AND uo_reconstructable AND twa_reconstructable AND NOT chronic_dialysis_or_esrd AND NOT prior_krt
  UNION ALL SELECT 11, 'final_all_comer_ratio_no_KRT_0_6h', count(*), count(*) FILTER (WHERE death_28d_inhospital=1) FROM e_gate_status WHERE ratio_ready
  UNION ALL SELECT 12, 'final_clean_ratio_no_loop_diuretic_proxy_0_6h', count(*), count(*) FILTER (WHERE death_28d_inhospital=1) FROM e_gate_status WHERE clean_ratio_ready
) x;

CREATE TEMP TABLE e_method_sensitivity ON COMMIT DROP AS
WITH bad AS (
  SELECT patientunitstayid, pressor_unit_or_conflict_problem FROM e_status
), wide AS (
  SELECT v.patientunitstayid, v.variant_name, v.twa_neq, v.active_minutes, v.supports_first_60min,
         b.pressor_unit_or_conflict_problem,
         max(v.twa_neq) FILTER (WHERE v.variant_name='cap240') OVER (PARTITION BY v.patientunitstayid) AS primary_twa
  FROM e_variant_twa v JOIN bad b USING (patientunitstayid)
)
SELECT variant_name,
       count(*) AS landmark_n,
       count(*) FILTER (WHERE twa_neq > 0 AND NOT pressor_unit_or_conflict_problem) AS reconstructable_n,
       count(*) FILTER (WHERE supports_first_60min) AS supports_primary_first60_n,
       round(percentile_cont(0.25) WITHIN GROUP (ORDER BY twa_neq)::numeric, 6) AS p25_twa,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY twa_neq)::numeric, 6) AS median_twa,
       round(percentile_cont(0.75) WITHIN GROUP (ORDER BY twa_neq)::numeric, 6) AS p75_twa,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY twa_neq/nullif(primary_twa,0))::numeric, 4) AS median_ratio_to_primary,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY active_minutes)::numeric, 1) AS median_active_minutes
FROM wide
GROUP BY variant_name
ORDER BY variant_name;

CREATE TEMP TABLE e_gate_metrics ON COMMIT DROP AS
WITH s AS (
  SELECT count(*)::bigint AS landmark_n,
         count(*) FILTER (WHERE valid_weight)::bigint AS weight_n,
         count(*) FILTER (WHERE uo_reconstructable)::bigint AS uo_n,
         count(*) FILTER (WHERE twa_reconstructable)::bigint AS twa_n,
         count(*) FILTER (WHERE ratio_ready)::bigint AS ratio_n,
         count(*) FILTER (WHERE ratio_ready AND death_28d_inhospital=1)::bigint AS ratio_deaths,
         count(*) FILTER (WHERE clean_ratio_ready)::bigint AS clean_n,
         count(*) FILTER (WHERE clean_ratio_ready AND death_28d_inhospital=1)::bigint AS clean_deaths,
         count(*) FILTER (WHERE uo_reconstructable AND uo_timepoints=1)::bigint AS single_uo_n,
         count(*) FILTER (WHERE ratio_ready AND twa_neq < 0.02)::bigint AS neq_lt002_n,
         count(*) FILTER (WHERE ratio_ready AND loop_0_6h_proxy)::bigint AS loop_0_6_n,
         count(*) FILTER (WHERE ratio_ready AND krt_6_24h)::bigint AS krt_6_24_n
  FROM e_gate_status
)
SELECT * FROM (
  SELECT 1 AS ord, 'landmark_base_n'::text AS metric, landmark_n::numeric AS value, landmark_n AS denominator_n, 100.0::numeric AS percent, 'descriptive'::text AS gate_rule, 'INFO'::text AS gate_status FROM s
  UNION ALL SELECT 2, 'valid_weight_n', weight_n, landmark_n, 100.0*weight_n/nullif(landmark_n,0), 'descriptive', 'INFO' FROM s
  UNION ALL SELECT 3, 'uo_reconstructable_n', uo_n, landmark_n, 100.0*uo_n/nullif(landmark_n,0), '>=60%', CASE WHEN 100.0*uo_n/nullif(landmark_n,0)>=60 THEN 'PASS' ELSE 'FAIL' END FROM s
  UNION ALL SELECT 4, 'twa_neq_reconstructable_n', twa_n, landmark_n, 100.0*twa_n/nullif(landmark_n,0), '>=80%', CASE WHEN 100.0*twa_n/nullif(landmark_n,0)>=80 THEN 'PASS' ELSE 'FAIL' END FROM s
  UNION ALL SELECT 5, 'final_all_comer_ratio_n', ratio_n, landmark_n, 100.0*ratio_n/nullif(landmark_n,0), '>=800', CASE WHEN ratio_n>=800 THEN 'PASS' ELSE 'FAIL' END FROM s
  UNION ALL SELECT 6, 'final_all_comer_deaths_28d_inhospital_n', ratio_deaths, ratio_n, 100.0*ratio_deaths/nullif(ratio_n,0), '>=100', CASE WHEN ratio_deaths>=100 THEN 'PASS' ELSE 'FAIL' END FROM s
  UNION ALL SELECT 7, 'final_clean_ratio_n', clean_n, ratio_n, 100.0*clean_n/nullif(ratio_n,0), '>=400', CASE WHEN clean_n>=400 THEN 'PASS' ELSE 'FAIL' END FROM s
  UNION ALL SELECT 8, 'final_clean_deaths_28d_inhospital_n', clean_deaths, clean_n, 100.0*clean_deaths/nullif(clean_n,0), '>=60', CASE WHEN clean_deaths>=60 THEN 'PASS' ELSE 'FAIL' END FROM s
  UNION ALL SELECT 9, 'single_UO_timepoint_among_UO_available_n', single_uo_n, uo_n, 100.0*single_uo_n/nullif(uo_n,0), 'audit; >=20% requires semantic judgment', 'AUDIT' FROM s
  UNION ALL SELECT 10, 'TWA_NEQ_lt_0_02_n', neq_lt002_n, ratio_n, 100.0*neq_lt002_n/nullif(ratio_n,0), '<=25%', CASE WHEN 100.0*neq_lt002_n/nullif(ratio_n,0)<=25 THEN 'PASS' ELSE 'FAIL' END FROM s
  UNION ALL SELECT 11, 'loop_diuretic_0_6h_proxy_n', loop_0_6_n, ratio_n, 100.0*loop_0_6_n/nullif(ratio_n,0), 'descriptive', 'INFO' FROM s
  UNION ALL SELECT 12, 'KRT_6_24h_n', krt_6_24_n, ratio_n, 100.0*krt_6_24_n/nullif(ratio_n,0), 'descriptive', 'INFO' FROM s
) q ORDER BY ord;

CREATE TEMP TABLE e_neq_qc ON COMMIT DROP AS
WITH x AS (SELECT * FROM e_gate_status WHERE ratio_ready), p AS (
  SELECT count(*) AS n,
         min(twa_neq) AS min_v,
         percentile_cont(0.01) WITHIN GROUP (ORDER BY twa_neq) AS p01,
         percentile_cont(0.05) WITHIN GROUP (ORDER BY twa_neq) AS p05,
         percentile_cont(0.10) WITHIN GROUP (ORDER BY twa_neq) AS p10,
         percentile_cont(0.25) WITHIN GROUP (ORDER BY twa_neq) AS p25,
         percentile_cont(0.50) WITHIN GROUP (ORDER BY twa_neq) AS p50,
         percentile_cont(0.75) WITHIN GROUP (ORDER BY twa_neq) AS p75,
         percentile_cont(0.90) WITHIN GROUP (ORDER BY twa_neq) AS p90,
         percentile_cont(0.95) WITHIN GROUP (ORDER BY twa_neq) AS p95,
         percentile_cont(0.99) WITHIN GROUP (ORDER BY twa_neq) AS p99,
         max(twa_neq) AS max_v,
         avg((twa_neq < 0.01)::int)*100.0 AS pct_lt001,
         avg((twa_neq < 0.02)::int)*100.0 AS pct_lt002,
         avg((twa_neq < 0.03)::int)*100.0 AS pct_lt003,
         avg((twa_neq < 0.05)::int)*100.0 AS pct_lt005,
         avg(active_minutes/360.0)*100.0 AS mean_active_pct,
         avg((active_agents=1)::int)*100.0 AS single_agent_pct,
         avg((active_agents>1)::int)*100.0 AS multi_agent_pct,
         avg(vasopressin_used::int)*100.0 AS vasopressin_pct,
         percentile_cont(0.99) WITHIN GROUP (ORDER BY scaled_uo_neq) AS ratio_p99
  FROM x
)
SELECT p.*,
       (SELECT 100.0*count(*) FILTER (WHERE x.twa_neq<0.02)/nullif(count(*),0)
        FROM x WHERE x.scaled_uo_neq>=p.ratio_p99) AS pct_top1_ratio_with_neq_lt002
FROM p;

CREATE TEMP TABLE e_uo_qc ON COMMIT DROP AS
SELECT count(*) FILTER (WHERE uo_reconstructable) AS uo_available_n,
       percentile_cont(0.25) WITHIN GROUP (ORDER BY uo_timepoints) FILTER (WHERE uo_reconstructable) AS p25_timepoints,
       percentile_cont(0.50) WITHIN GROUP (ORDER BY uo_timepoints) FILTER (WHERE uo_reconstructable) AS median_timepoints,
       percentile_cont(0.75) WITHIN GROUP (ORDER BY uo_timepoints) FILTER (WHERE uo_reconstructable) AS p75_timepoints,
       avg((uo_timepoints=1)::int) FILTER (WHERE uo_reconstructable)*100.0 AS single_timepoint_pct,
       avg(uo_observed_hours/6.0) FILTER (WHERE uo_reconstructable)*100.0 AS mean_hour_coverage_pct,
       avg((zero_timepoints>0)::int) FILTER (WHERE uo_reconstructable)*100.0 AS any_zero_pct,
       avg((urine_ml_6h=0)::int) FILTER (WHERE uo_reconstructable)*100.0 AS explicit_anuria_pct,
       avg((uo_ml_kg_h>3)::int) FILTER (WHERE uo_reconstructable)*100.0 AS pct_gt3_ml_kg_h,
       avg((uo_ml_kg_h>5)::int) FILTER (WHERE uo_reconstructable)*100.0 AS pct_gt5_ml_kg_h,
       avg((uo_ml_kg_h>10)::int) FILTER (WHERE uo_reconstructable)*100.0 AS pct_gt10_ml_kg_h,
       avg((duplicated_timepoints>0)::int) FILTER (WHERE uo_reconstructable)*100.0 AS any_same_offset_duplicate_pct,
       percentile_cont(0.50) WITHIN GROUP (ORDER BY max_entry_lag_min) FILTER (WHERE uo_reconstructable) AS median_max_entry_lag_min,
       avg((max_entry_lag_min>60)::int) FILTER (WHERE uo_reconstructable)*100.0 AS any_entry_lag_gt60_pct,
       avg((uo_timepoints=1 AND max_entry_lag_min>60)::int) FILTER (WHERE uo_reconstructable)*100.0 AS single_timepoint_and_entry_lag_gt60_pct
FROM e_gate_status;

CREATE TEMP TABLE e_contamination_qc ON COMMIT DROP AS
SELECT count(*) FILTER (WHERE ratio_ready) AS ratio_n,
       count(*) FILTER (WHERE ratio_ready AND loop_pre6h_proxy) AS loop_pre6h_proxy_n,
       count(*) FILTER (WHERE ratio_ready AND loop_0_6h_proxy) AS loop_0_6h_proxy_n,
       count(*) FILTER (WHERE ratio_ready AND loop_6_24h_proxy) AS loop_6_24h_proxy_n,
       count(*) FILTER (WHERE chronic_dialysis_or_esrd) AS chronic_dialysis_or_esrd_n,
       count(*) FILTER (WHERE prior_krt) AS prior_krt_n,
       count(*) FILTER (WHERE krt_0_6h) AS krt_0_6h_n,
       count(*) FILTER (WHERE ratio_ready AND krt_6_24h) AS krt_6_24h_n,
       'loop diuretic flags are medication-order/infusion-entry proxies; dose standardization UNRESOLVED'::text AS limitation
FROM e_gate_status;

CREATE TEMP TABLE e_decision ON COMMIT DROP AS
WITH m AS (
  SELECT max(value) FILTER (WHERE metric='landmark_base_n') AS landmark_n,
         max(percent) FILTER (WHERE metric='uo_reconstructable_n') AS uo_pct,
         max(percent) FILTER (WHERE metric='twa_neq_reconstructable_n') AS twa_pct,
         max(value) FILTER (WHERE metric='final_all_comer_ratio_n') AS ratio_n,
         max(value) FILTER (WHERE metric='final_all_comer_deaths_28d_inhospital_n') AS deaths,
         max(value) FILTER (WHERE metric='final_clean_ratio_n') AS clean_n,
         max(value) FILTER (WHERE metric='final_clean_deaths_28d_inhospital_n') AS clean_deaths
  FROM e_gate_metrics
), q AS (SELECT * FROM e_neq_qc), u AS (SELECT * FROM e_uo_qc)
SELECT CASE
         WHEN m.ratio_n<800 OR m.deaths<100 OR m.uo_pct<60 OR m.twa_pct<80
           THEN 'NO_GO_EXTERNAL_TRANSPORT_CANDIDATE_RULE'
         WHEN q.pct_lt002>25 THEN 'STOP_RATIO_DENOMINATOR_UNSTABLE'
         WHEN m.clean_n<400 OR m.clean_deaths<60 THEN 'BORDERLINE_CONSTRUCT_CONTAMINATION'
         ELSE 'PASS_NUMERIC_EICU_CAP240_RULE_LOCKED_OUTCOME_BLIND'
       END AS decision,
       m.*, q.pct_lt002, q.pct_top1_ratio_with_neq_lt002,
       u.single_timepoint_pct,
       '0-6h exposure is capped interval-weighted NEE with cap240 terminal carry; T0 confirmation requires immediate next usable same-agent record gap >0 and <=240 min, end=next_offset, no terminal carry'::text AS interval_rule_status,
       '28-day outcome is in-hospital death; alive hospital discharge is treated as alive at day 28'::text AS outcome_semantics,
       'this SQL builds repaired eICU data-gate and extract; ratio validity runs in 08_eicu_repaired_ratio_validity.py'::text AS analysis_boundary
FROM m CROSS JOIN q CROSS JOIN u;

CREATE TEMP TABLE e_pressor_normalization_dictionary ON COMMIT DROP AS
SELECT raw_drug_name,agent,unit_class,conversion_rule,
       coalesce(exclusion_reason,'usable_or_explicit_zero') AS normalization_status,
       count(*) AS rows,count(DISTINCT patientunitstayid) AS stays,
       count(*) FILTER (WHERE usable_positive_record=1) AS usable_positive_rows,
       count(*) FILTER (WHERE explicit_zero=1) AS explicit_zero_rows,
       count(*) FILTER (WHERE exclusion_reason IS NOT NULL) AS excluded_rows
FROM research_uo_neq_eicu_repair_v1.pressor_normalized_rows
GROUP BY raw_drug_name,agent,unit_class,conversion_rule,coalesce(exclusion_reason,'usable_or_explicit_zero')
ORDER BY agent,unit_class,rows DESC,raw_drug_name;

CREATE TEMP TABLE e_raw_to_nee_spotcheck ON COMMIT DROP AS
WITH eligible AS (
  SELECT n.*
  FROM research_uo_neq_eicu_repair_v1.pressor_normalized_rows n
  WHERE n.usable_positive_record=1
), combo_rows AS (
  SELECT * FROM (
    SELECT e.*,row_number() OVER (
      PARTITION BY agent,unit_class ORDER BY md5(patientunitstayid::text||':'||infusiondrugid::text||':UONEQ20260918')
    ) AS rn_combo
    FROM eligible e
  ) x WHERE rn_combo=1
), random_stays AS (
  SELECT patientunitstayid
  FROM (SELECT DISTINCT patientunitstayid,md5(patientunitstayid::text||':UONEQ20260918') AS h FROM eligible) x
  ORDER BY h LIMIT 50
), random_rows AS (
  SELECT DISTINCT ON (e.patientunitstayid) e.*,NULL::bigint AS rn_combo
  FROM eligible e JOIN random_stays r USING(patientunitstayid)
  ORDER BY e.patientunitstayid,md5(e.infusiondrugid::text||':row')
), picked AS (
  SELECT infusiondrugid,patientunitstayid,infusionoffset,raw_drug_name,raw_drugrate,rate_num,
         agent,unit_class,weight_kg,weight_source,conversion_rule,normalized_rate,ne_multiplier,ne_eq_rate
  FROM combo_rows
  UNION
  SELECT infusiondrugid,patientunitstayid,infusionoffset,raw_drug_name,raw_drugrate,rate_num,
         agent,unit_class,weight_kg,weight_source,conversion_rule,normalized_rate,ne_multiplier,ne_eq_rate
  FROM random_rows
), labeled AS (
  SELECT p.*,dense_rank() OVER (ORDER BY md5(patientunitstayid::text||':audit')) AS audit_stay_no
  FROM picked p
), total AS (
  SELECT patientunitstayid,infusionoffset,
         sum(dose_neq) FILTER (WHERE NOT has_unusable_positive AND NOT same_offset_dose_conflict) AS offset_level_nee
  FROM e_dose_seq GROUP BY patientunitstayid,infusionoffset
)
SELECT l.audit_stay_no,l.infusiondrugid,l.infusionoffset AS offset_min,
       l.raw_drug_name,l.raw_drugrate,l.rate_num,l.agent,l.unit_class,l.weight_kg,l.weight_source,
       l.conversion_rule,l.normalized_rate,l.ne_multiplier,l.ne_eq_rate,t.offset_level_nee
FROM labeled l LEFT JOIN total t USING(patientunitstayid,infusionoffset)
ORDER BY audit_stay_no,agent,unit_class,infusiondrugid;
SELECT * FROM e_pressor_normalization_dictionary
\g (format=csv) 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/CORRECTED_MANUSCRIPT_RESULTS_v1_1/03_QC/eicu_pressor_normalization_dictionary.csv'

SELECT * FROM e_t0_gap_audit
\g (format=csv) 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/CORRECTED_MANUSCRIPT_RESULTS_v1_1/03_QC/eicu_t0_confirmation_gap_audit.csv'

SELECT * FROM e_old_vs_fixed_t0
\g (format=csv) 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/CORRECTED_MANUSCRIPT_RESULTS_v1_1/03_QC/eicu_old_vs_fixed_t0.csv'

SELECT * FROM e_raw_to_nee_spotcheck
\g (format=csv) 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/CORRECTED_MANUSCRIPT_RESULTS_v1_1/03_QC/eicu_raw_to_nee_spotcheck.csv'
SELECT * FROM e_cohort_flow ORDER BY step
\g (format=csv) 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/CORRECTED_MANUSCRIPT_RESULTS_v1_1/02_DATA/cohort_flow_eicu.csv'

SELECT * FROM e_method_sensitivity
\g (format=csv) 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/CORRECTED_MANUSCRIPT_RESULTS_v1_1/03_QC/eicu_interval_method_sensitivity.csv'

SELECT * FROM e_gate_metrics ORDER BY ord
\g (format=csv) 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/CORRECTED_MANUSCRIPT_RESULTS_v1_1/03_QC/eicu_uo_neq_gate_metrics.csv'

SELECT * FROM e_neq_qc
\g (format=csv) 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/CORRECTED_MANUSCRIPT_RESULTS_v1_1/03_QC/eicu_neq_denominator_qc.csv'

SELECT * FROM e_uo_qc
\g (format=csv) 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/CORRECTED_MANUSCRIPT_RESULTS_v1_1/03_QC/eicu_uo_measurement_qc.csv'

SELECT * FROM e_contamination_qc
\g (format=csv) 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/CORRECTED_MANUSCRIPT_RESULTS_v1_1/03_QC/eicu_diuretic_krt_audit.csv'

SELECT * FROM e_decision
\g (format=csv) 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/CORRECTED_MANUSCRIPT_RESULTS_v1_1/10_DECISION/eicu_gate_decision.csv'

CREATE TEMP TABLE eicu_ratio_analysis ON COMMIT DROP AS
SELECT row_number() OVER (ORDER BY g.patientunitstayid) AS analysis_row,
       g.patientunitstayid AS local_stay_id,
       l.patienthealthsystemstayid AS local_hospital_stay_id,
       g.hospitalid,
       g.t0,
       CASE
         WHEN lower(coalesce(g.hospitaldischargestatus,hs.resolved_status,''))='expired'
          AND coalesce(g.hospitaldischargeoffset,hs.resolved_discharge_offset)>g.t0+360
          AND coalesce(g.hospitaldischargeoffset,hs.resolved_discharge_offset)<=g.t0+40320 THEN 1
         WHEN lower(coalesce(g.hospitaldischargestatus,hs.resolved_status,'')) IN ('alive','expired') THEN 0
       END AS death28,
       g.death_28d_inhospital AS death28_original,
       lower(coalesce(g.hospitaldischargestatus,hs.resolved_status,'')) AS resolved_hospital_discharge_status,
       coalesce(g.hospitaldischargeoffset,hs.resolved_discharge_offset) AS resolved_hospital_discharge_offset,
       g.weight_kg::double precision AS weight_kg,
       g.urine_ml_6h::double precision AS urine_ml_6h,
       g.uo_ml_kg_h::double precision AS uo_ml_kg_h,
       g.twa_neq::double precision AS twa_neq,
       g.scaled_uo_neq::double precision AS scaled_uo_neq,
       v60.twa_neq::double precision AS twa_neq_cap60,
       v360.twa_neq::double precision AS twa_neq_cap360,
       vnt.twa_neq::double precision AS twa_neq_no_terminal_cap240,
       (0.1*g.uo_ml_kg_h/nullif(v60.twa_neq,0))::double precision AS scaled_uo_neq_cap60,
       (0.1*g.uo_ml_kg_h/nullif(v360.twa_neq,0))::double precision AS scaled_uo_neq_cap360,
       (0.1*g.uo_ml_kg_h/nullif(vnt.twa_neq,0))::double precision AS scaled_uo_neq_no_terminal_cap240,
       (g.active_minutes/360.0)::double precision AS active_prop,
       (v60.active_minutes/360.0)::double precision AS active_prop_cap60,
       (v360.active_minutes/360.0)::double precision AS active_prop_cap360,
       (vnt.active_minutes/360.0)::double precision AS active_prop_no_terminal_cap240,
       g.clean_ratio_ready AS clean_cohort,
       g.chronic_dialysis_or_esrd, g.prior_krt, g.krt_0_6h,
       g.loop_pre6h_proxy, g.loop_0_6h_proxy, g.loop_6_24h_proxy,
       l.age::double precision AS age,
       (lower(coalesce(l.gender,''))='female')::int AS female,
       cr.creatinine::double precision AS baseline_creatinine,
       EXISTS(
         SELECT 1 FROM eicu_crd.diagnosis d
         WHERE d.patientunitstayid=g.patientunitstayid
           AND lower(coalesce(d.diagnosisstring,'')) ~ '(chronic kidney disease|chronic renal failure)'
       )::int AS ckd_proxy,
       l.sepsis_sofa::double precision AS cohort_sepsis_sofa,
       lac.lactate::double precision AS lactate_pre_t0,
       mp.map_pre_t0::double precision AS map_pre_t0,
       EXISTS(
         SELECT 1 FROM eicu_crd.treatment t
         WHERE t.patientunitstayid=g.patientunitstayid
           AND t.treatmentoffset>=g.t0-360 AND t.treatmentoffset<=g.t0
           AND lower(btrim(t.treatmentstring)) LIKE 'pulmonary|ventilation and oxygenation|mechanical ventilation%'
           AND lower(t.treatmentstring) NOT LIKE '%non-invasive%'
       )::int AS invasive_vent_pre_t0_proxy,
       g.uo_timepoints,g.uo_observed_hours,g.max_entry_lag_min
FROM e_gate_status g
JOIN e_landmark l USING(patientunitstayid)
JOIN eicu_crd.patient p0 USING(patientunitstayid)
LEFT JOIN e_variant_twa v60 ON v60.patientunitstayid=g.patientunitstayid AND v60.variant_name='cap60'
LEFT JOIN e_variant_twa v360 ON v360.patientunitstayid=g.patientunitstayid AND v360.variant_name='cap360'
LEFT JOIN e_variant_twa vnt ON vnt.patientunitstayid=g.patientunitstayid AND vnt.variant_name='no_terminal_cap240'
LEFT JOIN LATERAL (
  SELECT CASE WHEN bool_or(lower(coalesce(p2.hospitaldischargestatus,''))='expired') THEN 'expired'
              WHEN bool_or(lower(coalesce(p2.hospitaldischargestatus,''))='alive') THEN 'alive' END AS resolved_status,
         max((p2.hospitaldischargeoffset-p2.hospitaladmitoffset)+p0.hospitaladmitoffset) AS resolved_discharge_offset
  FROM eicu_crd.patient p2
  WHERE p2.patienthealthsystemstayid=p0.patienthealthsystemstayid
    AND lower(coalesce(p2.hospitaldischargestatus,'')) IN ('alive','expired')
) hs ON true
LEFT JOIN LATERAL (
  SELECT x.labresult AS creatinine
  FROM eicu_crd.lab x
  WHERE x.patientunitstayid=g.patientunitstayid
    AND lower(btrim(x.labname))='creatinine'
    AND lower(btrim(x.labmeasurenamesystem))='mg/dl'
    AND x.labresultoffset>=g.t0-1440 AND x.labresultoffset<=g.t0
    AND x.labresult>0 AND x.labresult<=150
  ORDER BY x.labresultoffset DESC,x.labid DESC LIMIT 1
) cr ON true
LEFT JOIN LATERAL (
  SELECT x.labresult AS lactate
  FROM eicu_crd.lab x
  WHERE x.patientunitstayid=g.patientunitstayid
    AND lower(btrim(x.labname))='lactate'
    AND lower(btrim(x.labmeasurenamesystem))='mmol/l'
    AND x.labresultoffset>=g.t0-360 AND x.labresultoffset<=g.t0
    AND x.labresult>0 AND x.labresult<50
  ORDER BY x.labresultoffset DESC LIMIT 1
) lac ON true
LEFT JOIN LATERAL (
  SELECT coalesce(
    (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY v.systemicmean)
     FROM eicu_crd.vitalperiodic v
     WHERE v.patientunitstayid=g.patientunitstayid
       AND v.observationoffset>=g.t0-120 AND v.observationoffset<=g.t0
       AND v.systemicmean BETWEEN 20 AND 200),
    (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY a.noninvasivemean)
     FROM eicu_crd.vitalaperiodic a
     WHERE a.patientunitstayid=g.patientunitstayid
       AND a.observationoffset>=g.t0-120 AND a.observationoffset<=g.t0
       AND a.noninvasivemean BETWEEN 20 AND 200)
  ) AS map_pre_t0
) mp ON true
WHERE g.ratio_ready;

CREATE TEMP TABLE eicu_hospital_measurement_coverage ON COMMIT DROP AS
SELECT hospitalid,count(*) AS landmark_n,
       count(*) FILTER (WHERE uo_reconstructable) AS uo_available_n,
       round(100.0*count(*) FILTER (WHERE uo_reconstructable)/nullif(count(*),0),4) AS uo_available_percent,
       count(*) FILTER (WHERE twa_reconstructable) AS nee_available_n,
       round(100.0*count(*) FILTER (WHERE twa_reconstructable)/nullif(count(*),0),4) AS nee_available_percent,
       count(*) FILTER (WHERE ratio_ready) AS ratio_analyzable_n,
       count(*) FILTER (WHERE clean_ratio_ready) AS clean_analyzable_n,
       (100.0*count(*) FILTER (WHERE uo_reconstructable)/nullif(count(*),0)>=60
        AND count(*) FILTER (WHERE ratio_ready)>=20) AS high_measurement_coverage_hospital
FROM e_gate_status GROUP BY hospitalid ORDER BY hospitalid;

SELECT * FROM eicu_ratio_analysis ORDER BY analysis_row
\g (format=csv) 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/PRIVATE_WORK/eicu_ratio_analysis.csv'

SELECT * FROM eicu_hospital_measurement_coverage
\g (format=csv) 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/CORRECTED_MANUSCRIPT_RESULTS_v1_1/03_QC/hospital_measurement_coverage_eicu.csv'

SELECT count(*) AS n,
       count(*) FILTER (WHERE clean_cohort) AS clean_n,
       count(*) FILTER (WHERE death28=1) AS deaths,
       count(*) FILTER (WHERE clean_cohort AND death28=1) AS clean_deaths,
       avg(active_prop) AS mean_active_prop,
       count(*) FILTER (WHERE active_prop>=0.5) AS active_ge50_n,
       count(*) FILTER (WHERE active_prop>=0.75) AS active_ge75_n
FROM eicu_ratio_analysis
\g (format=csv) 'D:/Clinical_Public_Database_Research/01_ICU_Research/UO_NEQ_FORMAL_20260918/v1.1_CORRECTED/CORRECTED_MANUSCRIPT_RESULTS_v1_1/03_QC/eicu_ratio_extract_qc.csv'

ROLLBACK;
\echo DONE_EICU_RATIO_VALIDITY_EXTRACT
