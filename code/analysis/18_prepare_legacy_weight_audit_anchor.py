"""Extract only the two v1.0 1/2-kg case keys for raw-source tracing; no modeling."""
from pathlib import Path

import pandas as pd

root = Path(r"D:\Clinical_Public_Database_Research\01_ICU_Research\UO_NEQ_FORMAL_20260918")
old = pd.read_csv(root / "PRIVATE_WORK/mimic_ratio_analysis.csv")
cases = old.loc[old.weight_kg.isin([1, 2]), ["local_stay_id", "t0", "weight_kg", "uo_ml_kg_h"]]
assert len(cases) == 2 and set(cases.weight_kg) == {1, 2}
cases.to_csv(root / "v1.1_CORRECTED/PRIVATE_WORK/legacy_weight_error_anchor.csv", index=False)
print("LEGACY_WEIGHT_SOURCE_ANCHOR_READY: 2 cases; no patient-data fitting")
