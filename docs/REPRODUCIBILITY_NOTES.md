# Reproducibility notes

This public release preserves the executed analytical logic. Some scripts retain local Windows file paths used during the original run; users must replace those paths before rerunning.

The repository intentionally excludes patient-level intermediate CSV files. Full reproduction therefore requires:
1. Authorized MIMIC-IV and eICU access.
2. Local PostgreSQL schemas compatible with the study scripts.
3. Reconstruction of local private intermediate files from the SQL extraction steps.

The corrected analysis used Python 3.12.14 and PostgreSQL 18.4. Package versions are listed in `requirements.txt`.

The source-closure files in this repository supersede the earlier pre-closure uncertainty regarding the eICU `e05_sepsis_cohort`.
