# Frozen SAP v1.0 — UO/NEQ

Version: 2026-09-18  
Status: FROZEN; formal analysis authorized

## Study position
Associational/prognostic phenotype study in adults with vasopressor-treated sepsis. MIMIC-IV is the discovery cohort and eICU is external replication. No causal treatment, renal perfusion, renal blood flow, or vasopressor responsiveness claim is permitted.

## Cohorts and time zero
MIMIC-IV uses the first eligible adult ICU stay with Sepsis-3 and first sustained intravenous vasopressor episode of at least 60 minutes. eICU uses the validated sepsis cohort and requires each agent-level confirmation interval to have a next positive dose record with gap >0 and <=240 minutes; terminal records and gaps >240 minutes cannot confirm T0. Patients must survive and remain observable through T0+6 h. The physiological-clean cohort excludes chronic dialysis/ESRD, pre-T0 KRT, 0–6 h KRT and 0–6 h loop diuretic exposure/proxy.

## Exposure and outcomes
UO_6h is cumulative urine output from T0 to T0+6 h divided by weight and 6. NEE is the five-agent norepinephrine-equivalent dose. MIMIC uses interval TWA; eICU uses capped interval-weighted NEE with cap240. scaled UO/NEQ = 0.1*UO_6h/average NEE, with no epsilon, winsorization or data-derived cutoff. Primary term: 4-knot RCS of asinh(scaled UO/NEQ), plus anuria indicator. MIMIC outcome is death after the 6 h landmark through T0+28 d. eICU outcome is 28-day in-hospital mortality; survival discharge is non-event.

## Model and missing data
Separate logistic models are fitted in each database. MIMIC clean 5th/35th/65th/95th percentile knots, MIMIC median reference and MIMIC P10/P25/P50/P75/P90 reporting levels are locked and applied to eICU. Core adjustment: age, sex, log1p baseline creatinine, CKD proxy, pre-T0 MAP and invasive ventilation at/before T0. Creatinine and MAP are multiply imputed (M=20); exposure and outcome are never imputed. Extended severity sensitivity adds pre-T0 lactate with M=50 and MIMIC pre-T0 SOFA.

## Benchmarks and inference
M1 baseline+UO; M2 baseline+log NEE; M3 baseline+UO+log NEE; M4 baseline+ratio. Report AUC, Brier and calibration; paired bootstrap=500. MIMIC receives optimism correction; eICU uses hospital cluster-robust inference and random-intercept hospital sensitivity. Prespecified S1–S8 are executed without post-result modification.

## Reporting boundary
UO/NEQ may be described only as a support-normalized renal output compression phenotype. It is not asserted to be a sufficient statistic or superior to jointly modeling UO and NEE.
