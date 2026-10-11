from pathlib import Path
import pandas as pd

ROOT = Path(r"D:\Clinical_Public_Database_Research\01_ICU_Research\UO_NEQ_FORMAL_20260918\v1.1_CORRECTED")
PRIVATE = ROOT / "PRIVATE_WORK"
PUBLIC = ROOT / "CORRECTED_MANUSCRIPT_RESULTS_v1_1"

for db in ("mimic", "eicu"):
    d = pd.read_csv(PRIVATE / f"{db}_ratio_analysis.csv")
    cols = ["analysis_row", "local_stay_id", "t0", "weight_kg", "urine_ml_6h", "uo_ml_kg_h"]
    if db == "mimic":
        cols += ["local_hadm_id"]
    a = d[cols].copy()
    a.to_csv(PRIVATE / f"{db}_source_anchor.csv", index=False)
    a.nlargest(30, "uo_ml_kg_h").to_csv(PRIVATE / f"{db}_extreme_anchor.csv", index=False)
    print(db, "ratio_n", len(d), "UO_gt10_n", int((d.uo_ml_kg_h > 10).sum()),
          "max_UO", d.uo_ml_kg_h.max())
    if db == "mimic":
        lineage = d[["analysis_row", "local_stay_id", "local_hadm_id", "t0",
                     "legacy_scr_baseline", "legacy_scr_min", "legacy_mdrd_est",
                     "legacy_creatinine_source_type", "legacy_min_first_source_time",
                     "legacy_min_last_source_time", "legacy_creatinine_time_status",
                     "baseline_creatinine", "creatinine_source_time", "creatinine_source_id",
                     "creatinine_minutes_before_t0"]].copy()
        lineage.to_csv(PRIVATE / "mimic_creatinine_lineage_by_case.csv", index=False)
        agg = lineage.groupby(["legacy_creatinine_source_type", "legacy_creatinine_time_status"],
                              dropna=False).agg(n=("analysis_row", "size"),
                                                corrected_measured_n=("baseline_creatinine", "count")).reset_index()
        agg.to_csv(PUBLIC / "01_SOURCE_LINEAGE/mimic_creatinine_lineage_summary.csv", index=False)
        pd.DataFrame([{"database": "MIMIC-IV", "n": len(d),
                       "v1_missing_n": int(d.legacy_scr_baseline.isna().sum()),
                       "v1_1_missing_n": int(d.baseline_creatinine.isna().sum()),
                       "changed_value_n": int(((d.legacy_scr_baseline - d.baseline_creatinine).abs() > 1e-8).sum()),
                       "source_time_verified_n": int(d.creatinine_source_time.notna().sum()),
                       "all_corrected_minutes_before_t0_within_24h": bool(d.loc[d.creatinine_source_time.notna(),
                                "creatinine_minutes_before_t0"].between(0, 1440).all())}]).to_csv(
            PUBLIC / "01_SOURCE_LINEAGE/mimic_creatinine_old_new_summary.csv", index=False)
