# UO/NEQ in vasopressor-treated sepsis

Analysis code for the manuscript:

**Urine output relative to vasopressor support and mortality in sepsis: a two-database cohort study**

This repository contains the study-specific SQL and Python code used for the final corrected analysis (v1.1) and the source-closure code required to reproduce the eICU sepsis cohort lineage.

## Authors

- Qiuxia Huang
- Long Huang
- Sheng Lin
- Fengfeng Lu

Corresponding author: Fengfeng Lu  
ORCID: https://orcid.org/0009-0004-6137-9795

## Study overview

The study evaluates urine output relative to norepinephrine-equivalent vasopressor support during the first 6 hours after sustained vasopressor initiation in adults with sepsis. MIMIC-IV is the primary cohort and eICU is an independent replication cohort.

Final corrected model cohorts:

- MIMIC-IV: 12,097 patients
- eICU: 1,803 patients

The public repository contains **code only**. It does not contain patient-level data, identifiers, credentials, database extracts, fitted patient-level predictions, or protected source records.

## Data access

MIMIC-IV and eICU are available through PhysioNet to credentialed users under their respective data-use agreements. Users must obtain their own authorized access before attempting a full rerun.

Do **not** commit or redistribute raw MIMIC-IV/eICU data through this repository.

## Directory structure

```text
code/
  analysis/                 corrected extraction, analysis, QC and material-generation scripts
  eicu_source/              recovered original eICU e05 cohort creation SQL and dependencies
docs/
  SOURCE_CLOSURE_CN.md
  EICU_SEPSIS_DEFINITION.txt
  EICU_SOFA_TIME_SEMANTICS.txt
  FROZEN_SAP_v1.0.md
CITATION.cff
.zenodo.json
requirements.txt
LICENSE
```

## Reproducibility status

The original eICU `e05_sepsis_cohort` creation code and dependencies were recovered and independently rebuilt. The rebuilt table matched the existing 11,649-member source table exactly, with zero membership discrepancies and zero discrepancies across the 29 stored fields. Therefore, the source-closure decision was `PASS_SOURCE_ONLY_NO_REMODEL`.

The final corrected analytical results remain v1.1.

## Software environment

The corrected analysis was run with:

- Python 3.12.14
- PostgreSQL 18.4
- numpy 2.3.5
- pandas 3.0.1
- scipy 1.18.1
- statsmodels 0.15.0
- scikit-learn 1.9.1
- matplotlib 3.11.2

Formal random seed: `20260918`.

## Execution outline

A full rerun requires local authorized copies of both databases and adaptation of local file paths.

### eICU source-cohort lineage

Run in this order:

1. `code/eicu_source/00_eicu_schema_precheck.sql`
2. `code/eicu_source/05F_eicu_final_convertibility_and_center_audit.sql`
3. `code/eicu_source/06_eicu_vasopressor_normalization.sql`
4. `code/eicu_source/01_e05_creation.sql`

The actual eICU sepsis definition used by the study is documented in `docs/EICU_SEPSIS_DEFINITION.txt`.

### Corrected study analysis

The corrected v1.1 workflow was executed in the following order:

1. `code/analysis/01_mimic_corrected_extract.sql`
2. `code/analysis/02_eicu_reextract.sql`
3. `code/analysis/07_prepare_source_anchors.py`
4. source/QC SQL: `08`, `09`, `10`, `12`, `13`, `14`
5. legacy weight audit: `18_prepare_legacy_weight_audit_anchor.py`, `19_mimic_verified_weight_errors.sql`
6. `code/analysis/03_corrected_analysis.py`
7. `code/analysis/05_build_materials_corrected.py --prepare-anchors`
8. material/QC SQL: `04`, `11`, `16`, `17`
9. `code/analysis/05_build_materials_corrected.py --build`
10. `code/analysis/15_finalize_corrected_package.py`

### Local paths

Some scripts retain the Windows paths used in the executed analysis for exact provenance. Before rerunning on another machine, replace the project-root/output paths with your own authorized local paths. These paths contain no passwords or database credentials.

## Important analytical notes

- eICU is an independent model refit/replication cohort, not validation of a locked MIMIC prediction model.
- The paired 500-bootstrap performance comparison conditions on fixed predictions; it is not full nested/pipeline validation.
- The eICU modified SOFA is a first-day construct. Its component timing is not fully aligned to the pressor-first T0; see `docs/EICU_SOFA_TIME_SEMANTICS.txt`.
- The study uses database-specific operational sepsis definitions. They should not be described as fully identical across databases.

## Privacy and security

Before running the scripts, keep all patient-level exports in a local private directory excluded by `.gitignore`. Never commit:

- MIMIC-IV/eICU source tables or extracts
- patient/stay identifiers
- case-level audit CSVs
- credentials, `.env` files or connection strings
- database dumps
- fitted patient-level prediction files

## Citation

Please cite the software release using the citation shown by GitHub/Zenodo after the `v1.0.0` release is archived.

## License

The analysis code in this repository is released under the MIT License. Use of the underlying MIMIC-IV and eICU data remains governed by the applicable PhysioNet licenses and data-use agreements.
