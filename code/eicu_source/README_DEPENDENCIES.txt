TRUE DEPENDENCY CHAIN FOR 01_e05_creation.sql

Original project root:
D:/MIMIC_projects/vasopressor_restart_v2/01_SQL/

Execution order used by the original project:
1. 00_eicu_schema_precheck.sql
   - Creates the research schema and extract_numeric(text) helper.
   - For e05 reconstruction, the helper is the required executable dependency.
2. 05F_eicu_final_convertibility_and_center_audit.sql
   - Reads eicu_crd.infusiondrug and eicu_crd.patient.
   - Produces s16_center_eligibility and the high/moderate-fidelity center classes.
3. 06_eicu_vasopressor_normalization.sql
   - Reads raw infusiondrug/patient plus s16_center_eligibility.
   - Produces e06_normalized_rows used by cardiovascular SOFA.
4. ../01_e05_creation.sql
   - Reads raw patient, diagnosis, admissiondx, lab and apacheapsvar plus the two dependencies above.
   - Produces e05_sepsis_cohort.

SHA-256:
00_eicu_schema_precheck.sql = f209a38d681156439d8417fd3386d27ee5a6a29f656e4fcda72f631d080babed
05F_eicu_final_convertibility_and_center_audit.sql = fbb007202af6aaa672c9ad3e4854e69a1de21884b358c3737ce04e7f0f984e69
06_eicu_vasopressor_normalization.sql = e7f0a79b4fab9e64645198e6a4ef826868ee8cbd7ec55ad81fb0a9fae6942593
01_e05_creation.sql = e07bc97255c94b7336ddc5094b5ba591dc78d8e6e690d977034cd2d2c8bb3506

These are the recovered original project files. They are not pg_dump table DDL,
table contents, or a later project's inferred definition.
