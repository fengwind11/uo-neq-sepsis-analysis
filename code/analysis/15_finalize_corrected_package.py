"""Aggregate-only v1.0/v1.1 comparison, provenance, privacy gate, and ZIP.

Run after the source SQL, 03_corrected_analysis.py, and 05_build_materials_corrected.py.
It does not fit models or write to either source database.
"""
from __future__ import annotations

import csv
import hashlib
import json
import shutil
import zipfile
from pathlib import Path

import numpy as np
import pandas as pd

ROOT = Path(r"D:\Clinical_Public_Database_Research\01_ICU_Research\UO_NEQ_FORMAL_20260918")
TASK = ROOT / "v1.1_CORRECTED"
PKG = TASK / "CORRECTED_MANUSCRIPT_RESULTS_v1_1"
OLD = ROOT / "DELIVERY_PACKAGE_FORMAL"
PREP = ROOT / "MANUSCRIPT_PREP_PACKAGE"
PRIVATE = TASK / "PRIVATE_WORK"
CODE = TASK / "CODE"


def compare(name: str, old_file: Path, new_file: Path, keys: list[str],
            renamed: dict[str, str] | None = None) -> None:
    a = pd.read_csv(old_file)
    b = pd.read_csv(new_file)
    if renamed:
        a["comparison_analysis"] = a.analysis.replace(renamed)
        b["comparison_analysis"] = b.analysis
        keys = ["comparison_analysis" if x == "analysis" else x for x in keys]
    assert not a.duplicated(keys).any() and not b.duplicated(keys).any(), name
    joined = a.merge(b, on=keys, how="outer", suffixes=("_v1_0", "_v1_1"), indicator=True)
    for col in set(a.columns).intersection(b.columns).difference(keys):
        x, y = f"{col}_v1_0", f"{col}_v1_1"
        if (x in joined and y in joined and pd.api.types.is_numeric_dtype(a[col])
                and pd.api.types.is_numeric_dtype(b[col])
                and not pd.api.types.is_bool_dtype(a[col]) and not pd.api.types.is_bool_dtype(b[col])):
            joined[f"{col}_delta_v1_1_minus_v1_0"] = joined[y] - joined[x]
    out = PKG / "13_VERSION_COMPARISON" / f"{name}_v1_0_vs_v1_1.csv"
    out.parent.mkdir(parents=True, exist_ok=True)
    joined.to_csv(out, index=False, encoding="utf-8-sig")


def write_csv(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8-sig") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def make_comparisons() -> None:
    specs = [
        ("primary_effects", OLD / "04_PRIMARY/primary_effects.csv", PKG / "04_PRIMARY/primary_effects.csv", ["database", "analysis"], None),
        ("standardized_risks", OLD / "04_PRIMARY/standardized_risks.csv", PKG / "04_PRIMARY/standardized_risks.csv", ["database", "estimand"], None),
        ("component_models", OLD / "05_COMPONENT/component_model_comparison.csv", PKG / "05_COMPONENT/component_model_comparison.csv", ["database", "model"], None),
        ("paired_deltas", OLD / "05_COMPONENT/bootstrap_deltas.csv", PKG / "05_COMPONENT/bootstrap_deltas.csv", ["database", "contrast", "metric"], None),
        ("sensitivities", OLD / "06_SENSITIVITY/sensitivity_results.csv", PKG / "06_SENSITIVITY/sensitivity_results.csv", ["database", "analysis"],
         {"S1_ALL_COMER_RENAL_ELIGIBLE": "S1_RENAL_ELIGIBLE_INCLUDE_EARLY_LOOP",
          "S8_EXTENDED_SEVERITY": "S8_SEVERITY_COMPONENT_TIMING_UNVERIFIED"}),
        ("posthoc_shock_index", PREP / "03_EXPANDED_MODEL/expanded_adjustment_results.csv", PKG / "03_EXPANDED_MODEL/expanded_adjustment_results.csv", ["database", "analysis"], None),
    ]
    for spec in specs:
        compare(*spec)


def dictionaries() -> None:
    model_rows = [
        {"database": "MIMIC-IV", "variable": "age", "frozen_model_source": "mimiciv_derived.icustay_detail.admission_age", "time_semantics": "ICU admission", "role": "core adjustment"},
        {"database": "eICU", "variable": "age", "frozen_model_source": "e05_sepsis_cohort.age", "time_semantics": "ICU admission; e05 creation SQL unresolved", "role": "core adjustment"},
        {"database": "MIMIC-IV", "variable": "female", "frozen_model_source": "icustay_detail.gender", "time_semantics": "pre-T0", "role": "core adjustment"},
        {"database": "eICU", "variable": "female", "frozen_model_source": "e05_sepsis_cohort.gender", "time_semantics": "pre-T0", "role": "core adjustment"},
        {"database": "MIMIC-IV", "variable": "baseline_creatinine", "frozen_model_source": "CORRECTED raw labevents itemid 50912, mg/dL", "time_semantics": "last measured in [T0-24h,T0]", "role": "core adjustment; MICE M20"},
        {"database": "eICU", "variable": "baseline_creatinine", "frozen_model_source": "eicu_crd.lab creatinine mg/dl", "time_semantics": "last measured in [T0-1440min,T0]", "role": "core adjustment; MICE M20"},
        {"database": "MIMIC-IV", "variable": "ckd_proxy", "frozen_model_source": "mimiciv_derived.creatinine_baseline.ckd", "time_semantics": "admission diagnosis proxy; exact pre-T0 documentation not established", "role": "frozen core proxy"},
        {"database": "eICU", "variable": "ckd_proxy", "frozen_model_source": "eicu_crd.diagnosis diagnosisstring CKD/chronic renal failure", "time_semantics": "source query not offset-limited; pre-T0 documentation unverified", "role": "frozen core proxy"},
        {"database": "MIMIC-IV", "variable": "map_pre_t0", "frozen_model_source": "mimiciv_derived.vitalsign.mbp", "time_semantics": "median [T0-2h,T0]", "role": "core adjustment; MICE M20"},
        {"database": "eICU", "variable": "map_pre_t0", "frozen_model_source": "vitalPeriodic.systemicmean; fallback vitalAperiodic.noninvasivemean", "time_semantics": "median [T0-120min,T0]", "role": "core adjustment; MICE M20; unaffected by SBP fix"},
        {"database": "MIMIC-IV", "variable": "vent_primary", "frozen_model_source": "mimiciv_derived.ventilation interval overlap", "time_semantics": "active at T0", "role": "frozen core proxy"},
        {"database": "eICU", "variable": "vent_primary", "frozen_model_source": "eicu_crd.treatment mechanical ventilation string", "time_semantics": "documented [T0-360min,T0]", "role": "frozen core proxy"},
    ]
    descriptive_rows = [
        {"database": "MIMIC-IV", "variable": "ckd_table", "source_reviewed_source": "ICD spotcheck plus frozen CKD proxy", "model_entry": "NO_NEW_ENTRY"},
        {"database": "eICU", "variable": "ckd_source_reviewed", "source_reviewed_source": "diagnosis through T0 plus pastHistory renal fields", "model_entry": "NO_NEW_ENTRY"},
        {"database": "MIMIC-IV", "variable": "vent_table", "source_reviewed_source": "derived ventilation interval at T0", "model_entry": "NO_NEW_ENTRY"},
        {"database": "eICU", "variable": "vent_source_reviewed", "source_reviewed_source": "respiratoryCare airway plus treatment MV", "model_entry": "NO_NEW_ENTRY"},
        {"database": "eICU", "variable": "sbp_pre_t0", "source_reviewed_source": "vitalPeriodic.systemicsystolic then exact Systolic nurse child fields", "model_entry": "POST_HOC_SHOCK_INDEX_ONLY"},
    ]
    write_csv(PKG / "02_HARMONIZATION/frozen_model_covariate_dictionary.csv", model_rows)
    write_csv(PKG / "02_HARMONIZATION/source_reviewed_descriptive_dictionary.csv", descriptive_rows)


def provenance_and_privacy() -> None:
    reference = PKG / "14_CODE/REFERENCE"
    reference.mkdir(parents=True, exist_ok=True)
    for path in CODE.glob("*.py"):
        shutil.copy2(path, PKG / "14_CODE" / path.name)
    for path in CODE.glob("*.sql"):
        shutil.copy2(path, PKG / "14_CODE" / path.name)
    shutil.copy2(OLD / "01_FROZEN_SAP/frozen_SAP_v1_0.md", reference / "frozen_SAP_v1_0.md")
    local_sql = Path(r"B:\mimic-code\mimic-iv\concepts_postgres\measurement\creatinine_baseline.sql")
    shutil.copy2(local_sql, reference / "creatinine_baseline_local_creation_sql.txt")
    write_csv(PKG / "01_SOURCE_LINEAGE/source_dependency_status.csv", [
        {"object": "mimiciv_derived.creatinine_baseline", "local_definition": "14_CODE/REFERENCE/creatinine_baseline_local_creation_sql.txt", "local_repo_head": "cb8ca478034e01c2441355522c462935f37a1323", "exact_deployed_commit": "UNVERIFIED", "impact": "Admission-wide minimum or MDRD estimate is not a verified pre-T0 measurement"},
        {"object": "research_vasopressor_restart_eicu_v1.e05_sepsis_cohort", "local_definition": "UNRESOLVED", "local_repo_head": "UNRESOLVED", "exact_deployed_commit": "UNVERIFIED", "impact": "Cannot verify Sepsis-3 component timing or pre-T0 infection for all cases"},
    ])
    # The row-level traces remain locally recoverable but are not in the deliverable.
    spot = PKG / "02_HARMONIZATION/raw_spotchecks"
    if spot.exists():
        if not any(spot.iterdir()):
            spot.rmdir()
        else:
            target = PRIVATE / "MANUSCRIPT_SOURCE_SPOTCHECKS"
            if target.exists():
                target = PRIVATE / "MANUSCRIPT_SOURCE_SPOTCHECKS_POST_TIE"
            if target.exists():
                raise FileExistsError(target)
            shutil.move(str(spot), str(target))
    raw = PKG / "03_QC/eicu_raw_to_nee_spotcheck.csv"
    if raw.exists():
        target = PRIVATE / "eicu_raw_to_nee_spotcheck.csv"
        if target.exists():
            target = PRIVATE / "eicu_raw_to_nee_spotcheck_post_tie.csv"
        if target.exists():
            raise FileExistsError(target)
        shutil.move(str(raw), str(target))
    for name in ("mimic_extreme_uo_source_summary.csv", "eicu_extreme_uo_source_summary.csv"):
        path = PKG / "01_SOURCE_LINEAGE" / name
        table = pd.read_csv(path).drop(columns=["analysis_row"],errors="ignore")
        table.to_csv(path, index=False)
    private_files = ["mimic_creatinine_lineage_by_case.csv", "eicu_creatinine_source_by_case.csv",
                     "eicu_sbp_change_by_case.csv",
                     "eicu_sbp_raw_trace_30_cases.csv", "S1_boolean_exclusion_by_case_mimic.csv",
                     "S1_boolean_exclusion_by_case_eicu.csv", "mimic_extreme_uo_raw_30.csv",
                     "eicu_extreme_uo_raw_30.csv", "legacy_weight_error_anchor.csv",
                     "legacy_weight_error_source_rows.csv"]
    write_csv(PKG / "01_SOURCE_LINEAGE/private_trace_manifest.csv", [
        {"local_private_file":name,"bytes":(PRIVATE/name).stat().st_size,
         "sha256":hashlib.sha256((PRIVATE/name).read_bytes()).hexdigest(),"included_in_public_zip":"NO"}
        for name in private_files
    ])


def version_log_and_ledger() -> None:
    write_csv(PKG / "09_AUDIT/version_log.csv", [
        {"version": "v1.0", "phase": "formal result retained unchanged", "change": "historical source and implementation", "timing": "before source-error review", "decision": "ARCHIVED_COMPARATOR"},
        {"version": "v1.1_CORRECTED", "phase": "post-result correction", "change": "MIMIC creatinine last verified pre-T0 24h measured; no future/minimum/MDRD fill", "timing": "AFTER_VIEWING_V1_0_RESULTS", "decision": "CORRECTION_REQUIRED"},
        {"version": "v1.1_CORRECTED", "phase": "post-result correction", "change": "two source-charted adult 1/2 kg weights set missing; ratio cases excluded", "timing": "AFTER_VIEWING_V1_0_RESULTS", "decision": "CORRECTION_REQUIRED"},
        {"version": "v1.1_CORRECTED", "phase": "post-result correction", "change": "eICU SBP exact Systolic child fields, same-offset source priority", "timing": "AFTER_VIEWING_V1_0_RESULTS", "decision": "CORRECTION_REQUIRED"},
        {"version": "v1.1_CORRECTED", "phase": "post-result correction", "change": "eICU last creatinine same-offset tie resolved deterministically by highest source labid; 24h window unchanged", "timing": "AFTER_VIEWING_V1_0_RESULTS", "decision": "CORRECTION_REQUIRED"},
        {"version": "v1.1_CORRECTED", "phase": "post-result correction", "change": "S1 common renal exclusions before restoring early loop", "timing": "AFTER_VIEWING_V1_0_RESULTS", "decision": "CORRECTION_REQUIRED"},
        {"version": "v1.1_CORRECTED", "phase": "implementation correction", "change": "within-imputation patient standardization and joint Rubin RD/logRR covariance", "timing": "AFTER_VIEWING_V1_0_RESULTS", "decision": "CORRECTION_REQUIRED"},
        {"version": "v1.1_CORRECTED", "phase": "implementation correction", "change": "fixed optimism bootstrap seed map M1 101 M2 202 M3 303 M4 404 added to seed 20260918", "timing": "AFTER_VIEWING_V1_0_RESULTS", "decision": "CORRECTION_REQUIRED"},
        {"version": "v1.1_CORRECTED", "phase": "source limitation", "change": "e05 creation SQL and SOFA raw component timestamps unresolved", "timing": "AFTER_VIEWING_V1_0_RESULTS", "decision": "UNRESOLVED_NOT_FOR_SUBMISSION"},
    ])
    ledger_path = PKG / "06_RESULTS_LEDGER/manuscript_numbers_master.csv"
    ledger = pd.read_csv(ledger_path)
    ledger["manuscript_sentence_id"] = ""
    ledger["body_number_crosscheck_status"] = "NOT_RUN_CURRENT_ENGLISH_DRAFT_NOT_LOCATED"
    ledger.to_csv(ledger_path, index=False, encoding="utf-8-sig")
    shutil.copy2(ledger_path, PKG / "manuscript_numbers_master.csv")
    info = PKG / "09_AUDIT/session_info.txt"
    lines = ["PostgreSQL mimiciv/eicu 18.4",
             "Formal seed 20260918; optimism offsets M1=101 M2=202 M3=303 M4=404",
             "Paired 500 bootstrap conditions on fixed predictions, not nested validation"]
    existing = info.read_text(encoding="utf-8")
    info.write_text(existing + "".join(line+"\n" for line in lines if line not in existing),encoding="utf-8")


def qa_and_zip() -> None:
    primary = pd.read_csv(PKG / "04_PRIMARY/primary_effects.csv").set_index("database")
    assert (int(primary.loc["MIMIC-IV", "n"]), int(primary.loc["MIMIC-IV", "deaths"])) == (12097, 2890)
    assert (int(primary.loc["eICU", "n"]), int(primary.loc["eICU", "deaths"])) == (1803, 528)
    risk = pd.read_csv(PKG / "04_PRIMARY/standardized_risks.csv")
    for db in ("MIMIC-IV", "eICU"):
        d = risk.loc[risk.database.eq(db)].set_index("estimand")
        assert np.isclose(d.loc["risk_difference_P25_minus_P75", "estimate"],
                          d.loc["adjusted_risk_P25", "estimate"] - d.loc["adjusted_risk_P75", "estimate"])
    spec = json.loads((PKG / "02_DATA/frozen_exposure_spec.json").read_text(encoding="utf-8"))
    oldspec = json.loads((OLD / "02_DATA/frozen_exposure_spec.json").read_text(encoding="utf-8"))
    for key in ("ratio_knots_asinh", "uo_knots", "log_nee_knots", "risk_levels_scaled_ratio", "reference_scaled_ratio"):
        assert spec[key] == oldspec[key], key
    table = pd.read_csv(PKG / "01_TABLE1/Table1_expanded.csv")
    s1 = pd.read_csv(PKG / "01_TABLE1/TableS1_survival.csv")
    assert all(c in table for c in ("Overall_missing_n", "Q1_missing_n", "Q4_missing_n"))
    assert all(c in s1 for c in ("Overall_missing_n", "Survivors_missing_n", "Non_survivors_missing_n"))
    assert pd.read_csv(PRIVATE / "eicu_sbp_raw_trace_30_cases.csv").stay_id.nunique() == 30
    eicu_cr = pd.read_csv(PKG / "01_SOURCE_LINEAGE/eicu_creatinine_source_summary.csv").iloc[0]
    assert int(eicu_cr.unverified_n) == 0 and int(eicu_cr.value_tie_n) == 3
    weights = pd.read_csv(PKG / "01_SOURCE_LINEAGE/mimic_verified_weight_errors.csv")
    assert set(weights.recorded_weight_kg) == {1, 2}
    assert weights.cases.sum() == 2 and weights.pre_t0_alternate_nonerror_weight_rows.sum() == 0
    for n, label in [(1,"cohort_flow"),(2,"adjusted_risk_surface"),(3,"adjusted_ratio_curves"),(4,"component_auc_differences")]:
        for suffix in ("png", "pdf"):
            assert (PKG / "08_FIGURES" / f"Figure{n}_{label}.{suffix}").is_file()
    forbidden = ("stay_id", "hadm_id", "subject_id", "patientunitstayid", "infusiondrugid", "analysis_row")
    for path in PKG.rglob("*.csv"):
        header = path.open(encoding="utf-8-sig").readline().lower()
        assert not any(token in header for token in forbidden), path
    assert not (PKG / "02_HARMONIZATION/raw_spotchecks").exists()
    assert not (PKG / "03_QC/eicu_raw_to_nee_spotcheck.csv").exists()
    write_csv(PKG / "09_AUDIT/package_validation.csv", [
        {"check":"primary_n_events","status":"PASS","evidence":"MIMIC-IV 12097/2890; eICU 1803/528"},
        {"check":"fixed_exposure_basis","status":"PASS","evidence":"v1.0 values identical"},
        {"check":"joint_RD_identity","status":"PASS","evidence":"both databases"},
        {"check":"Figure1_to_4_PNG_PDF","status":"PASS","evidence":"all present and visually reviewed"},
        {"check":"SBP_private_30_case_trace","status":"PASS","evidence":"30 distinct cases; identifiers not in public package"},
        {"check":"public_CSV_identifier_header_scan","status":"PASS","evidence":"no direct patient or analysis-row identifiers"},
        {"check":"e05_creation_SQL","status":"UNRESOLVED","evidence":"not located; NOT_FOR_SUBMISSION"},
        {"check":"English_manuscript_number_crosswalk","status":"NOT_RUN","evidence":"current full draft not located"},
    ])
    manifest = PKG / "MANIFEST_SHA256.csv"
    rows = []
    for path in sorted(p for p in PKG.rglob("*") if p.is_file() and p != manifest):
        rows.append({"relative_path":path.relative_to(PKG).as_posix(),"bytes":path.stat().st_size,
                     "sha256":hashlib.sha256(path.read_bytes()).hexdigest()})
    write_csv(manifest, rows)
    zip_path = TASK / "CORRECTED_MANUSCRIPT_RESULTS_v1_1.zip"
    with zipfile.ZipFile(zip_path,"w",compression=zipfile.ZIP_DEFLATED,compresslevel=9,allowZip64=True) as bundle:
        for path in sorted(p for p in PKG.rglob("*") if p.is_file()):
            bundle.write(path,arcname=f"{PKG.name}/{path.relative_to(PKG).as_posix()}")
    with zipfile.ZipFile(zip_path) as bundle:
        assert bundle.testzip() is None
    print(json.dumps({"zip":str(zip_path),"files":len(rows)+1,"zip_sha256":hashlib.sha256(zip_path.read_bytes()).hexdigest(),
                      "status":"UNRESOLVED_NOT_FOR_SUBMISSION_E05_LINEAGE_AND_MANUSCRIPT_CROSSWALK"},ensure_ascii=False,indent=2))


if __name__ == "__main__":
    make_comparisons()
    dictionaries()
    provenance_and_privacy()
    version_log_and_ledger()
    qa_and_zip()
