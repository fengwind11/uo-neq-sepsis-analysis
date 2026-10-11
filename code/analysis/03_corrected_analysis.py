from __future__ import annotations

import json
import math
import platform
import sys
import warnings
from dataclasses import dataclass
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
import scipy
import sklearn
import statsmodels.api as sm
from scipy.stats import chi2, norm
from sklearn.experimental import enable_iterative_imputer  # noqa: F401
from sklearn.impute import IterativeImputer
from sklearn.metrics import brier_score_loss, roc_auc_score

ROOT = Path(r"D:\Clinical_Public_Database_Research\01_ICU_Research\UO_NEQ_FORMAL_20260918\v1.1_CORRECTED")
PKG = ROOT / "CORRECTED_MANUSCRIPT_RESULTS_v1_1"
PRIVATE = ROOT / "PRIVATE_WORK"
V1 = ROOT.parent / "DELIVERY_PACKAGE_FORMAL"
DATA = PKG / "02_DATA"
QC = PKG / "03_QC"
PRIMARY = PKG / "04_PRIMARY"
COMP = PKG / "05_COMPONENT"
SENS = PKG / "06_SENSITIVITY"
TABLES = PKG / "07_TABLES"
FIGS = PKG / "08_FIGURES"
AUDIT = PKG / "09_AUDIT"
DECISION = PKG / "10_DECISION"

SEED = 20260918
OPTIMISM_SEED_OFFSET = {"M1": 101, "M2": 202, "M3": 303, "M4": 404}
M_CORE = 20
M_EXT = 50
PAIRED_BOOT = 500
OPTIMISM_BOOT = 100

for folder in [DATA, QC, PRIMARY, COMP, SENS, TABLES, FIGS, AUDIT, DECISION]:
    folder.mkdir(parents=True, exist_ok=True)


def boolify(s: pd.Series) -> pd.Series:
    if pd.api.types.is_bool_dtype(s):
        return s.fillna(False)
    return s.astype(str).str.strip().str.lower().map(
        {"true": True, "t": True, "1": True, "false": False, "f": False, "0": False}
    ).fillna(False)


def load_dataset(db: str) -> pd.DataFrame:
    d = pd.read_csv(PRIVATE / f"{db}_ratio_analysis.csv")
    for col in d.columns:
        if col == "clean_cohort" or col.startswith(("loop_", "krt_", "chronic_", "prior_krt")):
            d[col] = boolify(d[col])
    numeric = [
        "death28", "death28_inhospital", "uo_ml_kg_h", "twa_neq", "scaled_uo_neq",
        "active_prop", "age", "female", "baseline_creatinine", "ckd_proxy",
        "lactate_pre_t0", "map_pre_t0", "pre_t0_sepsis_sofa", "cohort_sepsis_sofa",
        "invasive_vent_t0", "invasive_vent_pre_t0_proxy", "hospitalid",
        "uo_rows", "uo_distinct_times", "uo_timepoints", "uo_observed_hours",
        "max_entry_lag_min", "twa_neq_cap60", "twa_neq_cap360",
        "twa_neq_no_terminal_cap240", "scaled_uo_neq_cap60",
        "scaled_uo_neq_cap360", "scaled_uo_neq_no_terminal_cap240",
        "active_prop_cap60", "active_prop_cap360", "active_prop_no_terminal_cap240",
    ]
    for col in numeric:
        if col in d:
            d[col] = pd.to_numeric(d[col], errors="coerce")
    d["database"] = "MIMIC-IV" if db == "mimic" else "eICU"
    d["anuria"] = (d["uo_ml_kg_h"] == 0).astype(int)
    d["ratio_asinh"] = np.arcsinh(d["scaled_uo_neq"])
    d["log_nee"] = np.log(d["twa_neq"])
    d["vent"] = d["invasive_vent_t0"] if db == "mimic" else d["invasive_vent_pre_t0_proxy"]
    return d


def rcs_terms(x: np.ndarray, knots: list[float], prefix: str) -> pd.DataFrame:
    x = np.asarray(x, dtype=float)
    k = np.asarray(knots, dtype=float)
    if len(k) != 4 or not np.all(np.diff(k) > 0):
        raise ValueError(f"Invalid four-knot RCS specification for {prefix}: {knots}")
    out = {f"{prefix}_linear": x}
    denom = (k[-1] - k[0]) ** 2
    for j in range(len(k) - 2):
        term = (
            np.maximum(x - k[j], 0) ** 3
            - np.maximum(x - k[-2], 0) ** 3 * (k[-1] - k[j]) / (k[-1] - k[-2])
            + np.maximum(x - k[-1], 0) ** 3 * (k[-2] - k[j]) / (k[-1] - k[-2])
        ) / denom
        out[f"{prefix}_rcs{j+1}"] = term
    return pd.DataFrame(out, index=getattr(x, "index", None))


def zparams(s: pd.Series, transform=None) -> tuple[float, float]:
    v = pd.to_numeric(s, errors="coerce")
    if transform is not None:
        v = transform(v)
    return float(v.mean()), float(v.std(ddof=0) or 1.0)


def make_spec(mimic: pd.DataFrame, eicu: pd.DataFrame) -> dict:
    m = mimic.loc[mimic.clean_cohort & mimic.death28.notna()].copy()
    spec = {
        "ratio_knots_asinh": np.quantile(m.ratio_asinh, [0.05, 0.35, 0.65, 0.95]).tolist(),
        "uo_knots": np.quantile(m.uo_ml_kg_h, [0.05, 0.35, 0.65, 0.95]).tolist(),
        "log_nee_knots": np.quantile(m.log_nee, [0.05, 0.35, 0.65, 0.95]).tolist(),
        "reference_scaled_ratio": float(m.scaled_uo_neq.median()),
        "reference_asinh_ratio": float(m.ratio_asinh.median()),
        "risk_levels_scaled_ratio": {f"P{int(q*100)}": float(m.scaled_uo_neq.quantile(q)) for q in [.10, .25, .50, .75, .90]},
        "ratio_asinh_mean": float(m.ratio_asinh.mean()),
        "ratio_asinh_sd": float(m.ratio_asinh.std(ddof=0)),
        "bootstrap_seed": SEED,
        "paired_bootstrap_replicates": PAIRED_BOOT,
        "mice_core_m": M_CORE,
        "mice_extended_m": M_EXT,
    }
    for name, d in [("mimic", mimic), ("eicu", eicu)]:
        c = d.loc[d.clean_cohort & d.death28.notna()].copy()
        spec[name] = {
            "age": zparams(c.age),
            "log1p_creatinine": zparams(c.baseline_creatinine, np.log1p),
            "map": zparams(c.map_pre_t0),
            "log1p_lactate": zparams(c.lactate_pre_t0, np.log1p),
        }
        if name == "mimic":
            spec[name]["sofa"] = zparams(c.pre_t0_sepsis_sofa)
    return spec


def multiple_imputations(d: pd.DataFrame, db: str, m: int, extended: bool, seed: int) -> list[pd.DataFrame]:
    targets = ["baseline_creatinine", "map_pre_t0"]
    if extended:
        targets.append("lactate_pre_t0")
        if db == "mimic":
            targets.append("pre_t0_sepsis_sofa")
    predictors = ["age", "female", "ckd_proxy", "vent", "death28", "ratio_asinh", "uo_ml_kg_h", "log_nee"]
    if "cohort_sepsis_sofa" in d:
        predictors.append("cohort_sepsis_sofa")
    cols = list(dict.fromkeys(predictors + targets))
    mat = d[cols].astype(float).copy()
    min_values, max_values = [], []
    bounds = {
        "baseline_creatinine": (0.05, 20.0), "map_pre_t0": (20.0, 200.0),
        "lactate_pre_t0": (0.1, 30.0), "pre_t0_sepsis_sofa": (0.0, 24.0),
    }
    for col in cols:
        lo, hi = bounds.get(col, (-np.inf, np.inf))
        min_values.append(lo); max_values.append(hi)
    imputer = IterativeImputer(
        max_iter=10, sample_posterior=True, random_state=seed,
        min_value=np.asarray(min_values), max_value=np.asarray(max_values),
        skip_complete=True,
    )
    imputer.fit(mat)
    out = []
    for i in range(m):
        imputer.random_state_ = np.random.RandomState(seed + i + 1)
        arr = imputer.transform(mat)
        x = d.copy()
        filled = pd.DataFrame(arr, columns=cols, index=d.index)
        for col in targets:
            x[col] = filled[col]
        out.append(x)
    return out


def build_design(d: pd.DataFrame, db: str, spec: dict, model: str, extended: bool = False,
                 ratio_col: str = "scaled_uo_neq", nee_col: str = "twa_neq") -> pd.DataFrame:
    p = spec[db]
    X = pd.DataFrame(index=d.index)
    X["const"] = 1.0
    X["age_z"] = (d.age - p["age"][0]) / p["age"][1]
    X["female"] = d.female.astype(float)
    X["creatinine_log_z"] = (np.log1p(d.baseline_creatinine) - p["log1p_creatinine"][0]) / p["log1p_creatinine"][1]
    X["ckd_proxy"] = d.ckd_proxy.astype(float)
    X["map_z"] = (d.map_pre_t0 - p["map"][0]) / p["map"][1]
    X["vent"] = d.vent.astype(float)
    if extended:
        X["lactate_log_z"] = (np.log1p(d.lactate_pre_t0) - p["log1p_lactate"][0]) / p["log1p_lactate"][1]
        if db == "mimic":
            X["sofa_z"] = (d.pre_t0_sepsis_sofa - p["sofa"][0]) / p["sofa"][1]
    if model in {"M1", "M3"}:
        terms = rcs_terms(d.uo_ml_kg_h.to_numpy(), spec["uo_knots"], "uo")
        terms.index = d.index
        X = pd.concat([X, terms], axis=1)
        X["anuria"] = d.anuria.astype(float)
    if model in {"M2", "M3"}:
        log_nee = np.log(d[nee_col].astype(float))
        terms = rcs_terms(log_nee.to_numpy(), spec["log_nee_knots"], "nee")
        terms.index = d.index
        X = pd.concat([X, terms], axis=1)
    if model == "M4":
        ratio_asinh = np.arcsinh(d[ratio_col].astype(float))
        terms = rcs_terms(ratio_asinh.to_numpy(), spec["ratio_knots_asinh"], "ratio")
        terms.index = d.index
        X = pd.concat([X, terms], axis=1)
        X["anuria"] = d.anuria.astype(float)
    if model == "LINEAR_RATIO":
        ratio_asinh = np.arcsinh(d[ratio_col].astype(float))
        X["ratio_z_mimic"] = (ratio_asinh - spec["ratio_asinh_mean"]) / spec["ratio_asinh_sd"]
        X["anuria"] = d.anuria.astype(float)
    if not np.isfinite(X.to_numpy()).all():
        raise ValueError(f"Non-finite design matrix for {db} {model}")
    return X


@dataclass
class PooledFit:
    beta: pd.Series
    cov: pd.DataFrame
    predictions: np.ndarray
    columns: list[str]
    designs: list[pd.DataFrame]
    betas: list[np.ndarray]


def pooled_fit(imps: list[pd.DataFrame], db: str, spec: dict, model: str,
               extended: bool = False, ratio_col: str = "scaled_uo_neq",
               nee_col: str = "twa_neq", cluster: bool = False) -> PooledFit:
    betas, covs, preds, designs = [], [], [], []
    for d in imps:
        X = build_design(d, db, spec, model, extended, ratio_col, nee_col)
        y = d.death28.astype(int).to_numpy()
        glm = sm.GLM(y, X, family=sm.families.Binomial())
        if cluster and "hospitalid" in d:
            res = glm.fit(maxiter=200, cov_type="cluster", cov_kwds={"groups": d.hospitalid.to_numpy()})
        else:
            res = glm.fit(maxiter=200)
        betas.append(np.asarray(res.params))
        covs.append(np.asarray(res.cov_params()))
        preds.append(np.asarray(res.predict(X)))
        designs.append(X)
    q = np.vstack(betas)
    qbar = q.mean(axis=0)
    w = np.mean(covs, axis=0)
    b = np.cov(q, rowvar=False, ddof=1) if len(q) > 1 else np.zeros_like(w)
    total = w + (1.0 + 1.0 / len(q)) * b
    cols = designs[0].columns.tolist()
    return PooledFit(pd.Series(qbar, index=cols), pd.DataFrame(total, index=cols, columns=cols),
                     np.mean(preds, axis=0), cols, designs, betas)


def wald_test(fit: PooledFit, names: list[str]) -> tuple[float, int, float]:
    idx = [fit.columns.index(x) for x in names]
    b = fit.beta.iloc[idx].to_numpy()
    v = fit.cov.iloc[idx, idx].to_numpy()
    stat = float(b.T @ np.linalg.pinv(v) @ b)
    return stat, len(idx), float(chi2.sf(stat, len(idx)))


def calibration(y: np.ndarray, pred: np.ndarray) -> tuple[float, float]:
    p = np.clip(pred, 1e-7, 1 - 1e-7)
    lp = np.log(p / (1 - p))
    res = sm.GLM(y, sm.add_constant(lp), family=sm.families.Binomial()).fit()
    return float(res.params[0]), float(res.params[1])


def _standardization_base(fit: PooledFit, imps: list[pd.DataFrame], db: str):
    if hasattr(fit, "_standardization_cache"):
        return fit._standardization_cache
    cache = []
    for j, d in enumerate(imps):
        X = fit.designs[j].to_numpy()
        beta = fit.betas[j]
        y = d.death28.to_numpy(dtype=float)
        p = scipy.special.expit(X @ beta)
        bread = np.linalg.pinv(X.T @ ((p * (1 - p))[:, None] * X))
        # ponytail: cache the score influence once per imputation; risk grids reuse it.
        beta_if = len(d) * (X * (y - p)[:, None]) @ bread
        groups = d.hospitalid.to_numpy() if db == "eicu" else None
        cache.append((beta_if, groups))
    fit._standardization_cache = cache
    return cache


def standardized_mi(fit: PooledFit, imps: list[pd.DataFrame], db: str, spec: dict,
                    values: list[float], extended: bool = False,
                    ratio_col: str = "scaled_uo_neq", nee_col: str = "twa_neq"):
    """Within each MI: patient-standardized risks and joint cluster influence covariance."""
    q, u = [], []
    for j, d in enumerate(imps):
        beta_if, groups = _standardization_base(fit, imps, db)[j]
        beta = fit.betas[j]
        risks, influences = [], []
        for value in values:
            x = d.copy()
            x[ratio_col] = value
            x["anuria"] = 0  # positive-ratio estimand, including anuria discontinuity fixed at zero
            Xstar = build_design(x, db, spec, "M4", extended, ratio_col, nee_col).to_numpy()
            pstar = scipy.special.expit(Xstar @ beta)
            risk = float(pstar.mean())
            grad = np.mean((pstar * (1 - pstar))[:, None] * Xstar, axis=0)
            risks.append(risk)
            influences.append(pstar - risk + beta_if @ grad)
        influence = np.column_stack(influences)
        if groups is not None:
            _, idx = np.unique(groups, return_inverse=True)
            cluster_sum = np.zeros((idx.max() + 1, len(values)))
            np.add.at(cluster_sum, idx, influence)
            within = (cluster_sum.T @ cluster_sum) / len(d)**2 * len(cluster_sum) / (len(cluster_sum) - 1)
        else:
            within = (influence.T @ influence) / len(d)**2
        q.append(risks)
        u.append(within)
    q = np.asarray(q)
    u = np.asarray(u)
    w = u.mean(axis=0)
    b = np.atleast_2d(np.cov(q, rowvar=False, ddof=1))
    return q.mean(axis=0), w + (1 + 1 / len(imps)) * b, q, u


def standardized_at(fit: PooledFit, imps: list[pd.DataFrame], db: str, spec: dict,
                    scaled_value: float, extended: bool = False,
                    ratio_col: str = "scaled_uo_neq", nee_col: str = "twa_neq") -> tuple[float, float, float, np.ndarray]:
    mean, cov, _, _ = standardized_mi(fit, imps, db, spec, [scaled_value], extended, ratio_col, nee_col)
    risk = float(mean[0]); se = math.sqrt(max(0.0, float(cov[0, 0])))
    return risk, max(0.0, risk - 1.96 * se), min(1.0, risk + 1.96 * se), np.array([])


def primary_results(imps: list[pd.DataFrame], db: str, spec: dict, extended: bool = False,
                    ratio_col: str = "scaled_uo_neq", nee_col: str = "twa_neq",
                    label: str = "primary") -> tuple[pd.DataFrame, PooledFit, PooledFit]:
    cluster = db == "eicu"
    fit = pooled_fit(imps, db, spec, "M4", extended, ratio_col, nee_col, cluster)
    linear = pooled_fit(imps, db, spec, "LINEAR_RATIO", extended, ratio_col, nee_col, cluster)
    overall = wald_test(fit, ["ratio_linear", "ratio_rcs1", "ratio_rcs2", "anuria"])
    nonlinear = wald_test(fit, ["ratio_rcs1", "ratio_rcs2"])
    b = float(linear.beta["ratio_z_mimic"])
    se = math.sqrt(float(linear.cov.loc["ratio_z_mimic", "ratio_z_mimic"]))
    rows = [{
        "database": "MIMIC-IV" if db == "mimic" else "eICU", "analysis": label,
        "n": len(imps[0]), "deaths": int(imps[0].death28.sum()),
        "overall_wald_chi2": overall[0], "overall_df": overall[1], "overall_p": overall[2],
        "nonlinearity_wald_chi2": nonlinear[0], "nonlinearity_df": nonlinear[1], "nonlinearity_p": nonlinear[2],
        "or_per_1sd_lower_asinh_ratio": math.exp(-b),
        "or_ci_low": math.exp(-b - 1.96 * se), "or_ci_high": math.exp(-b + 1.96 * se),
        "mice_m": len(imps), "cluster_robust_hospital": cluster,
    }]
    return pd.DataFrame(rows), fit, linear


def standardization_table(fit: PooledFit, imps: list[pd.DataFrame], db: str, spec: dict,
                          extended: bool = False) -> pd.DataFrame:
    labels = list(spec["risk_levels_scaled_ratio"])
    values = [spec["risk_levels_scaled_ratio"][x] for x in labels]
    pooled, total_cov, q, u = standardized_mi(fit, imps, db, spec, values, extended)
    rows = []
    for j, (label, value) in enumerate(zip(labels, values)):
        risk = float(pooled[j]); se = math.sqrt(max(0.0, float(total_cov[j, j])))
        lo, hi = max(0.0, risk - 1.96 * se), min(1.0, risk + 1.96 * se)
        rows.append({"database": "MIMIC-IV" if db == "mimic" else "eICU", "estimand": f"adjusted_risk_{label}",
                     "scaled_uo_neq": value, "estimate": risk, "ci_low": lo, "ci_high": hi})
    i25, i75 = labels.index("P25"), labels.index("P75")
    rd_j = q[:, i25] - q[:, i75]
    rd_u = u[:, i25, i25] + u[:, i75, i75] - 2 * u[:, i25, i75]
    rd = float(rd_j.mean())
    se_rd = math.sqrt(max(0.0, float(rd_u.mean() + (1 + 1 / len(q)) * rd_j.var(ddof=1))))
    rows.append({"database": "MIMIC-IV" if db == "mimic" else "eICU", "estimand": "risk_difference_P25_minus_P75",
                 "scaled_uo_neq": np.nan, "estimate": rd, "ci_low": rd - 1.96 * se_rd, "ci_high": rd + 1.96 * se_rd})
    logrr_j = np.log(q[:, i25] / q[:, i75])
    logrr_u = u[:, i25, i25] / q[:, i25]**2 + u[:, i75, i75] / q[:, i75]**2 - 2*u[:, i25, i75] / (q[:, i25]*q[:, i75])
    logrr = float(logrr_j.mean())
    se_logrr = math.sqrt(max(0.0, float(logrr_u.mean() + (1 + 1 / len(q)) * logrr_j.var(ddof=1))))
    rows.append({"database": "MIMIC-IV" if db == "mimic" else "eICU", "estimand": "risk_ratio_P25_over_P75",
                 "scaled_uo_neq": np.nan, "estimate": math.exp(logrr), "ci_low": math.exp(logrr - 1.96 * se_logrr), "ci_high": math.exp(logrr + 1.96 * se_logrr)})
    return pd.DataFrame(rows)


def component_models(imps: list[pd.DataFrame], db: str, spec: dict) -> tuple[pd.DataFrame, dict[str, np.ndarray], dict[str, PooledFit]]:
    y = imps[0].death28.astype(int).to_numpy()
    rows, preds, fits = [], {}, {}
    for model, title in [("M1", "baseline_plus_UO"), ("M2", "baseline_plus_NEE"),
                         ("M3", "baseline_plus_UO_plus_NEE"), ("M4", "baseline_plus_ratio")]:
        fit = pooled_fit(imps, db, spec, model, cluster=(db == "eicu"))
        pred = fit.predictions
        auc = roc_auc_score(y, pred); brier = brier_score_loss(y, pred)
        cint, cslope = calibration(y, pred)
        rows.append({"database": "MIMIC-IV" if db == "mimic" else "eICU", "model": model,
                     "description": title, "n": len(y), "deaths": int(y.sum()),
                     "auc_apparent": auc, "brier_apparent": brier,
                     "calibration_intercept": cint, "calibration_slope": cslope,
                     "mice_m": len(imps)})
        preds[model] = pred; fits[model] = fit
    return pd.DataFrame(rows), preds, fits


def optimism_correction(df: pd.DataFrame, db: str, spec: dict, model: str, apparent_auc: float,
                        apparent_brier: float, reps: int = OPTIMISM_BOOT) -> tuple[float, float, int]:
    rng = np.random.default_rng(SEED + OPTIMISM_SEED_OFFSET[model])
    X = build_design(df, db, spec, model).to_numpy()
    y = df.death28.astype(int).to_numpy(); n = len(y)
    auc_opt, brier_opt, used = [], [], 0
    for _ in range(reps):
        idx = rng.integers(0, n, n)
        if len(np.unique(y[idx])) < 2:
            continue
        try:
            r = sm.GLM(y[idx], X[idx], family=sm.families.Binomial()).fit(maxiter=100, disp=0)
            pb = np.asarray(r.predict(X[idx])); pt = np.asarray(r.predict(X))
            auc_opt.append(roc_auc_score(y[idx], pb) - roc_auc_score(y, pt))
            brier_opt.append(brier_score_loss(y[idx], pb) - brier_score_loss(y, pt))
            used += 1
        except Exception:
            continue
    return apparent_auc - float(np.mean(auc_opt)), apparent_brier - float(np.mean(brier_opt)), used


def paired_bootstrap_deltas(d: pd.DataFrame, preds: dict[str, np.ndarray], db: str) -> pd.DataFrame:
    rng = np.random.default_rng(SEED + (0 if db == "mimic" else 10000))
    y = d.death28.astype(int).to_numpy(); n = len(y)
    rows = []
    for comparator in ["M1", "M2", "M3"]:
        vals_auc, vals_brier = [], []
        for _ in range(PAIRED_BOOT):
            if db == "eicu":
                hospitals = d.hospitalid.dropna().unique()
                sampled = rng.choice(hospitals, size=len(hospitals), replace=True)
                idx = np.concatenate([np.flatnonzero(d.hospitalid.to_numpy() == h) for h in sampled])
            else:
                idx = rng.integers(0, n, n)
            if len(np.unique(y[idx])) < 2:
                continue
            vals_auc.append(roc_auc_score(y[idx], preds["M4"][idx]) - roc_auc_score(y[idx], preds[comparator][idx]))
            vals_brier.append(brier_score_loss(y[idx], preds["M4"][idx]) - brier_score_loss(y[idx], preds[comparator][idx]))
        for metric, values in [("AUC", vals_auc), ("Brier", vals_brier)]:
            arr = np.asarray(values)
            rows.append({"database": "MIMIC-IV" if db == "mimic" else "eICU", "contrast": f"M4_minus_{comparator}",
                         "metric": metric, "estimate": float(arr.mean()),
                         "ci_low": float(np.quantile(arr, .025)), "ci_high": float(np.quantile(arr, .975)),
                         "bootstrap_replicates": len(arr), "cluster_bootstrap_hospital": db == "eicu", "seed": SEED})
    return pd.DataFrame(rows)


def sensitivity_fit(imps: list[pd.DataFrame], mask: pd.Series, db: str, spec: dict, name: str,
                    ratio_col: str = "scaled_uo_neq", nee_col: str = "twa_neq",
                    outcome_col: str = "death28", extended: bool = False) -> dict:
    subset = []
    for d in imps:
        x = d.loc[mask].copy()
        x["death28"] = pd.to_numeric(x[outcome_col], errors="coerce")
        x = x.loc[x.death28.notna() & x[ratio_col].notna() & (x[nee_col] > 0)].copy()
        x["anuria"] = (x.uo_ml_kg_h == 0).astype(int)
        subset.append(x)
    if len(subset[0]) < 100 or subset[0].death28.sum() < 20:
        return {"database": "MIMIC-IV" if db == "mimic" else "eICU", "analysis": name,
                "n": len(subset[0]), "deaths": int(subset[0].death28.sum()), "status": "SPARSE_NOT_FIT"}
    pri, fit, linear = primary_results(subset, db, spec, extended, ratio_col, nee_col, name)
    std = standardization_table(fit, subset, db, spec, extended=extended)
    rd = std.loc[std.estimand.eq("risk_difference_P25_minus_P75")].iloc[0]
    rr = std.loc[std.estimand.eq("risk_ratio_P25_over_P75")].iloc[0]
    row = pri.iloc[0].to_dict()
    row.update({"p25_minus_p75_rd": rd.estimate, "rd_ci_low": rd.ci_low, "rd_ci_high": rd.ci_high,
                "p25_over_p75_rr": rr.estimate, "rr_ci_low": rr.ci_low, "rr_ci_high": rr.ci_high,
                "status": "FIT"})
    return row


def table1_long(d: pd.DataFrame, db: str) -> pd.DataFrame:
    x = d.loc[d.clean_cohort & d.death28.notna()].copy()
    x["ratio_quartile"] = pd.qcut(x.scaled_uo_neq, 4, labels=["Q1", "Q2", "Q3", "Q4"], duplicates="drop")
    rows = []
    cont = ["age", "baseline_creatinine", "map_pre_t0", "lactate_pre_t0", "uo_ml_kg_h", "twa_neq", "scaled_uo_neq"]
    binary = ["female", "ckd_proxy", "vent", "anuria"]
    for q, g in x.groupby("ratio_quartile", observed=True):
        rows.append({"database": db, "quartile": str(q), "variable": "N", "summary": str(len(g))})
        rows.append({"database": db, "quartile": str(q), "variable": "Deaths", "summary": f"{int(g.death28.sum())} ({100*g.death28.mean():.1f}%)"})
        for col in cont:
            v = pd.to_numeric(g[col], errors="coerce").dropna()
            rows.append({"database": db, "quartile": str(q), "variable": col,
                         "summary": f"{v.median():.3g} [{v.quantile(.25):.3g}, {v.quantile(.75):.3g}]" if len(v) else "NA"})
        for col in binary:
            v = pd.to_numeric(g[col], errors="coerce").dropna()
            rows.append({"database": db, "quartile": str(q), "variable": col,
                         "summary": f"{int(v.sum())} ({100*v.mean():.1f}%)" if len(v) else "NA"})
    return pd.DataFrame(rows)


def curve_source(fit: PooledFit, imps: list[pd.DataFrame], db: str, spec: dict) -> pd.DataFrame:
    positive = imps[0].scaled_uo_neq
    grid = np.linspace(float(positive.quantile(.01)), float(positive.quantile(.99)), 120)
    rows = []
    for value in grid:
        risk, lo, hi, _ = standardized_at(fit, imps, db, spec, value)
        rows.append({"database": "MIMIC-IV" if db == "mimic" else "eICU", "scaled_uo_neq": value,
                     "asinh_ratio": np.arcsinh(value), "adjusted_risk": risk, "ci_low": lo, "ci_high": hi})
    return pd.DataFrame(rows)


def surface_source(fit: PooledFit, imps: list[pd.DataFrame], db: str, spec: dict) -> pd.DataFrame:
    """M3 additive surface: standardize within each MI, then average risks."""
    d = imps[0]
    ug = np.linspace(float(d.uo_ml_kg_h.quantile(.02)), float(d.uo_ml_kg_h.quantile(.98)), 45)
    ng = np.exp(np.linspace(float(d.log_nee.quantile(.02)), float(d.log_nee.quantile(.98)), 45))
    grid_uo = np.repeat(ug, len(ng)); grid_nee = np.tile(ng, len(ug))
    u_terms = rcs_terms(grid_uo, spec["uo_knots"], "uo")
    n_terms = rcs_terms(np.log(grid_nee), spec["log_nee_knots"], "nee")
    expo = pd.concat([u_terms, pd.Series((grid_uo == 0).astype(float), name="anuria"), n_terms], axis=1)
    expo_cols = expo.columns.tolist()
    core_cols = [c for c in fit.columns if c not in expo_cols]
    assert len(core_cols) + len(expo_cols) == len(fit.columns)
    risk_sum = np.zeros(len(grid_uo))
    for j, imp in enumerate(imps):
        beta = pd.Series(fit.betas[j], index=fit.columns)
        base_lp = fit.designs[j][core_cols].to_numpy() @ beta[core_cols].to_numpy()
        expo_lp = expo.to_numpy() @ beta[expo_cols].to_numpy()
        for start in range(0, len(expo_lp), 50):
            stop = min(start + 50, len(expo_lp))
            risk_sum[start:stop] += scipy.special.expit(base_lp[:, None] + expo_lp[None, start:stop]).mean(axis=0)
        if j == 0:
            # ponytail: three direct-design checks guard the vectorized additive decomposition.
            for k in (0, len(grid_uo)//2, len(grid_uo)-1):
                x = imp.copy()
                x["uo_ml_kg_h"] = grid_uo[k]; x["twa_neq"] = grid_nee[k]
                x["anuria"] = int(grid_uo[k] == 0)
                direct = scipy.special.expit(build_design(x, db, spec, "M3").to_numpy() @ fit.betas[j]).mean()
                assert np.isclose(risk_sum[k], direct, rtol=1e-10, atol=1e-12)
    return pd.DataFrame({"database":"MIMIC-IV" if db == "mimic" else "eICU",
                         "uo_ml_kg_h":grid_uo,"twa_neq":grid_nee,
                         "adjusted_risk":risk_sum / len(imps),"scaled_uo_neq":0.1 * grid_uo / grid_nee,
                         "surface_method":"within_MI_patient_standardized_M3_additive_no_interaction"})


def save_figures(curves: pd.DataFrame, surfaces: pd.DataFrame, comp_rows: pd.DataFrame,
                 boot: pd.DataFrame, cohort_counts: dict):
    plt.rcParams.update({"font.family": "sans-serif", "font.sans-serif": ["Arial", "DejaVu Sans"],
                         "pdf.fonttype": 42, "svg.fonttype": "none", "font.size": 7,
                         "axes.spines.top": False, "axes.spines.right": False, "axes.linewidth": .8,
                         "legend.frameon": False})
    colors = {"MIMIC-IV": "#326D8C", "eICU": "#D17A52"}

    fig, axes = plt.subplots(1, 2, figsize=(7.2, 3.3))
    for ax, db in zip(axes, ["MIMIC-IV", "eICU"]):
        c = cohort_counts[db]
        labels = ["Ratio-ready", "Clean", "Modeled"]
        vals = [c["ratio_n"], c["clean_n"], c["model_n"]]
        ax.barh(labels[::-1], vals[::-1], color=["#D9E4EA", "#7FA8BA", colors[db]][::-1])
        for i, v in enumerate(vals[::-1]): ax.text(v, i, f" {v:,}", va="center", fontsize=7)
        ax.set_title(f"{db} cohort flow")
        ax.set_xlabel("Patients")
    fig.tight_layout()
    for ext, kw in [("png", {"dpi": 600}), ("pdf", {})]: fig.savefig(FIGS / f"Figure1_cohort_flow.{ext}", bbox_inches="tight", **kw)
    plt.close(fig)

    fig, axes = plt.subplots(1, 2, figsize=(7.2, 3.35), sharey=False)
    for ax, db in zip(axes, ["MIMIC-IV", "eICU"]):
        z = surfaces.loc[surfaces.database.eq(db)]
        U = np.sort(z.uo_ml_kg_h.unique()); N = np.sort(z.twa_neq.unique())
        Z = z.pivot(index="twa_neq", columns="uo_ml_kg_h", values="adjusted_risk").loc[N, U].to_numpy()
        cf = ax.contourf(U, N, Z, levels=16, cmap="viridis")
        for rv in [0.1, .5, 1, 2, 5]:
            yy = np.geomspace(N.min(), N.max(), 200); xx = 10 * rv * yy
            ok = (xx >= U.min()) & (xx <= U.max())
            if ok.any(): ax.plot(xx[ok], yy[ok], color="white", lw=.6, alpha=.8)
        ax.set_yscale("log"); ax.set_title(db); ax.set_xlabel("UO (mL/kg/h)"); ax.set_ylabel("Average NEE (mcg/kg/min)")
        fig.colorbar(cf, ax=ax, label="Adjusted mortality risk")
    fig.suptitle("Additive UO + NEE risk surface (M3; no interaction)", fontsize=8)
    fig.tight_layout(rect=(0, 0, 1, .95))
    for ext, kw in [("png", {"dpi": 600}), ("pdf", {})]: fig.savefig(FIGS / f"Figure2_adjusted_risk_surface.{ext}", bbox_inches="tight", **kw)
    plt.close(fig)

    fig, ax = plt.subplots(figsize=(6.9, 4.0))
    for db in ["MIMIC-IV", "eICU"]:
        c = curves.loc[curves.database.eq(db)]
        ax.plot(c.scaled_uo_neq, c.adjusted_risk, lw=1.8, color=colors[db], label=db)
        ax.fill_between(c.scaled_uo_neq, c.ci_low, c.ci_high, color=colors[db], alpha=.18, linewidth=0)
    ax.set_xscale("symlog", linthresh=.03)
    ax.set_xlabel("Scaled UO/NEQ (0.1 x mL/kg/h per mcg/kg/min)")
    ax.set_ylabel("Adjusted 28-day mortality risk")
    ax.set_title("Adjusted risk across the support-normalized renal output phenotype")
    ax.legend()
    fig.tight_layout()
    for ext, kw in [("png", {"dpi": 600}), ("pdf", {})]: fig.savefig(FIGS / f"Figure3_adjusted_ratio_curves.{ext}", bbox_inches="tight", **kw)
    plt.close(fig)

    b = boot.loc[boot.metric.eq("AUC")].copy()
    b["label"] = b.database + " " + b.contrast.str.replace("_minus_", "-", regex=False)
    fig, ax = plt.subplots(figsize=(6.8, 3.8))
    y = np.arange(len(b))
    ax.errorbar(b.estimate, y, xerr=[b.estimate-b.ci_low, b.ci_high-b.estimate], fmt="o", color="#326D8C", ecolor="#7FA8BA", capsize=2)
    ax.axvline(0, color="#555555", lw=.8)
    ax.axvline(-.02, color="#B24745", lw=.8, ls="--", label="Prespecified -0.02 stop line")
    ax.set_yticks(y, b.label); ax.set_xlabel("Paired AUC difference"); ax.set_title("Information compression benchmark")
    ax.legend(loc="upper right")
    fig.tight_layout()
    for ext, kw in [("png", {"dpi": 600}), ("pdf", {})]: fig.savefig(FIGS / f"Figure4_component_auc_differences.{ext}", bbox_inches="tight", **kw)
    plt.close(fig)


def random_intercept_sensitivity(imp: pd.DataFrame, spec: dict) -> dict:
    from statsmodels.genmod.bayes_mixed_glm import BinomialBayesMixedGLM
    X = build_design(imp, "eicu", spec, "M4")
    Z = pd.get_dummies(imp.hospitalid.astype(int).astype(str), drop_first=False).astype(float)
    ident = np.zeros(Z.shape[1], dtype=int)
    model = BinomialBayesMixedGLM(imp.death28.astype(int).to_numpy(), X.to_numpy(), Z.to_numpy(), ident)
    res = model.fit_vb()
    beta = np.asarray(res.fe_mean)
    lo = np.asarray(res.fe_mean) - 1.96 * np.asarray(res.fe_sd)
    hi = np.asarray(res.fe_mean) + 1.96 * np.asarray(res.fe_sd)
    names = X.columns.tolist()
    return {"status": "FIT_VB", "n": len(imp), "deaths": int(imp.death28.sum()), "hospitals": int(imp.hospitalid.nunique()),
            "ratio_linear_beta": float(beta[names.index("ratio_linear")]),
            "ratio_linear_ci_low": float(lo[names.index("ratio_linear")]),
            "ratio_linear_ci_high": float(hi[names.index("ratio_linear")]),
            "hospital_random_intercept_sd": float(np.exp(res.vcp_mean[0]))}


def main():
    warning_messages = []
    mimic = load_dataset("mimic")
    eicu = load_dataset("eicu")
    mimic_clean = mimic.loc[mimic.clean_cohort & mimic.death28.notna()].copy()
    eicu_clean = eicu.loc[eicu.clean_cohort & eicu.death28.notna()].copy()
    mimic_clean.to_csv(PRIVATE / "formal_clean_mimic.csv", index=False)
    eicu_clean.to_csv(PRIVATE / "formal_clean_eicu.csv", index=False)

    spec = make_spec(mimic, eicu)
    locked = json.loads((V1 / "02_DATA/frozen_exposure_spec.json").read_text(encoding="utf-8"))
    for key in ("ratio_knots_asinh", "uo_knots", "log_nee_knots", "reference_scaled_ratio",
                "reference_asinh_ratio", "risk_levels_scaled_ratio", "ratio_asinh_mean", "ratio_asinh_sd"):
        spec[key] = locked[key]
    assert np.all(np.diff(spec["ratio_knots_asinh"]) > 0)  # v1.0 knots remain fixed after source corrections
    (DATA / "frozen_exposure_spec.json").write_text(json.dumps(spec, indent=2), encoding="utf-8")

    var_rows = [
        ("scaled_uo_neq", "0.1 x UO_6h / average NEE_6h", "continuous", "primary exposure; no epsilon"),
        ("ratio_asinh", "asinh(scaled UO/NEQ)", "continuous", "4-knot RCS; knots fixed in MIMIC"),
        ("anuria", "UO_6h equals zero", "binary", "separate discontinuity term"),
        ("death28", "death after 6h landmark through T0+28d", "binary", "MIMIC all-cause; eICU in-hospital"),
        ("age", "age at ICU admission", "continuous", "pre-T0"),
        ("female", "female sex", "binary", "pre-T0"),
        ("baseline_creatinine", "last source-verified measured creatinine in T0-24h through T0", "mg/dL", "MICE in core model; corrected after v1.0 results"),
        ("ckd_proxy", "CKD indicator", "binary", "pre-T0"),
        ("map_pre_t0", "median MAP before T0", "mmHg", "MICE in core model"),
        ("vent", "invasive ventilation at or before T0", "binary", "eICU proxy"),
        ("lactate_pre_t0", "last pre-T0 lactate", "mmol/L", "extended model M=50"),
    ]
    pd.DataFrame(var_rows, columns=["variable", "definition", "unit_or_type", "role"]).to_csv(DATA / "variable_dictionary.csv", index=False)

    exposure_rows = []
    for name, d in [("MIMIC-IV", mimic_clean), ("eICU", eicu_clean)]:
        for var in ["uo_ml_kg_h", "twa_neq", "scaled_uo_neq", "ratio_asinh", "active_prop"]:
            v = pd.to_numeric(d[var], errors="coerce")
            qs = v.quantile([0, .01, .05, .10, .25, .50, .75, .90, .95, .99, 1])
            row = {"database": name, "variable": var, "n": int(v.notna().sum()), "missing_n": int(v.isna().sum())}
            row.update({f"p{int(q*100):02d}": float(val) for q, val in qs.items()})
            exposure_rows.append(row)
    pd.DataFrame(exposure_rows).to_csv(QC / "exposure_distribution.csv", index=False)

    mi_core = {
        "mimic": multiple_imputations(mimic_clean, "mimic", M_CORE, False, SEED + 10),
        "eicu": multiple_imputations(eicu_clean, "eicu", M_CORE, False, SEED + 20),
    }
    mi_ext = {
        "mimic": multiple_imputations(mimic_clean, "mimic", M_EXT, True, SEED + 30),
        "eicu": multiple_imputations(eicu_clean, "eicu", M_EXT, True, SEED + 40),
    }

    primary_frames, std_frames, primary_fits = [], [], {}
    for db in ["mimic", "eicu"]:
        pr, fit, _ = primary_results(mi_core[db], db, spec)
        primary_frames.append(pr); std_frames.append(standardization_table(fit, mi_core[db], db, spec))
        primary_fits[db] = fit
    primary = pd.concat(primary_frames, ignore_index=True)
    standardized = pd.concat(std_frames, ignore_index=True)
    primary.to_csv(PRIMARY / "primary_effects.csv", index=False)
    primary.loc[primary.database.eq("MIMIC-IV")].to_csv(PRIMARY / "primary_effects_mimic.csv", index=False)
    primary.loc[primary.database.eq("eICU")].to_csv(PRIMARY / "primary_effects_eicu.csv", index=False)
    standardized.to_csv(PRIMARY / "standardized_risks.csv", index=False)

    comp_frames, boot_frames, calibration_frames, comp_fits = [], [], [], {}
    for db, d in [("mimic", mimic_clean), ("eicu", eicu_clean)]:
        cm, preds, fits = component_models(mi_core[db], db, spec)
        if db == "mimic":
            corrected = []
            for _, row in cm.iterrows():
                auc_c, brier_c, used = optimism_correction(mi_core[db][0], db, spec, row.model, row.auc_apparent, row.brier_apparent)
                corrected.append((auc_c, brier_c, used))
            cm["auc_optimism_corrected"] = [x[0] for x in corrected]
            cm["brier_optimism_corrected"] = [x[1] for x in corrected]
            cm["optimism_bootstrap_replicates"] = [x[2] for x in corrected]
        else:
            cm["auc_optimism_corrected"] = np.nan; cm["brier_optimism_corrected"] = np.nan; cm["optimism_bootstrap_replicates"] = 0
        comp_frames.append(cm)
        calibration_frames.append(cm[["database", "model", "n", "deaths", "calibration_intercept", "calibration_slope"]])
        boot_frames.append(paired_bootstrap_deltas(d.reset_index(drop=True), preds, db))
        comp_fits[db] = fits
    comp_all = pd.concat(comp_frames, ignore_index=True)
    boot_all = pd.concat(boot_frames, ignore_index=True)
    comp_all.to_csv(COMP / "component_model_comparison.csv", index=False)
    boot_all.to_csv(COMP / "bootstrap_deltas.csv", index=False)
    pd.concat(calibration_frames, ignore_index=True).to_csv(COMP / "calibration.csv", index=False)

    sens_rows = []
    for db, d in [("mimic", mimic), ("eicu", eicu)]:
        known = d.death28.notna()
        base_clean = d.clean_cohort & known
        sens_rows.append(sensitivity_fit(mi_core[db], pd.Series(True, index=mi_core[db][0].index), db, spec, "PRIMARY_CLEAN"))
        # S1 puts early loop-diuretic exposure back into the renal-eligible ratio cohort.
        if db == "mimic":
            chronic_exclusion = d.chronic_dialysis
            pre_krt_exclusion = d.krt_pre_t0
            early_krt_exclusion = d.krt_0_6
            early_loop_exclusion = d.loop_0_6
        else:
            chronic_exclusion = d.chronic_dialysis_or_esrd
            pre_krt_exclusion = d.prior_krt
            early_krt_exclusion = d.krt_0_6h
            early_loop_exclusion = d.loop_0_6h_proxy
        no_chronic = ~chronic_exclusion
        no_pre_krt = no_chronic & ~pre_krt_exclusion
        renal = no_pre_krt & ~early_krt_exclusion
        assert (d.loc[known, "clean_cohort"] == (renal & ~d["loop_0_6" if db == "mimic" else "loop_0_6h_proxy"])[known]).all()
        private_chain = pd.DataFrame({"analysis_row":d.analysis_row,"known_outcome":known,
            "exclude_chronic_dialysis_or_esrd":chronic_exclusion,
            "exclude_pre_t0_krt":pre_krt_exclusion,"exclude_0_6h_krt":early_krt_exclusion,
            "exclude_0_6h_loop":early_loop_exclusion,"renal_eligible":renal,
            "primary_clean":base_clean,"death28":d.death28})
        private_chain.to_csv(PRIVATE / f"S1_boolean_exclusion_by_case_{db}.csv",index=False)
        chain = [("ratio_with_known_outcome",known,"sequential"),
                 ("no_chronic_dialysis_or_ESRD",known & no_chronic,"sequential"),
                 ("plus_no_pre_T0_KRT",known & no_pre_krt,"sequential"),
                 ("plus_no_0_6h_KRT_renal_eligible",known & renal,"sequential"),
                 ("primary_after_0_6h_loop_exclusion",base_clean,"sequential"),
                 ("excluded_chronic_dialysis_or_ESRD",known & chronic_exclusion,"parallel_flag"),
                 ("excluded_pre_T0_KRT",known & pre_krt_exclusion,"parallel_flag"),
                 ("excluded_0_6h_KRT",known & early_krt_exclusion,"parallel_flag"),
                 ("excluded_0_6h_loop",known & renal & early_loop_exclusion,"parallel_after_renal")]
        flow = pd.DataFrame([{"step":name,"n":int(mask.sum()),"deaths":int(d.loc[mask,"death28"].sum()),"step_type":typ}
                             for name,mask,typ in chain])
        flow.insert(0, "database", "MIMIC-IV" if db == "mimic" else "eICU")
        flow.to_csv(QC / f"S1_renal_exclusion_chain_{db}.csv", index=False)
        all_d = d.loc[known & renal].copy()
        all_imp = multiple_imputations(all_d, db, M_CORE, False, SEED + (50 if db == "mimic" else 60))
        sens_rows.append(sensitivity_fit(all_imp, pd.Series(True, index=all_d.index), db, spec, "S1_RENAL_ELIGIBLE_INCLUDE_EARLY_LOOP"))
        clean_d = d.loc[base_clean].copy()
        clean_imp = mi_core[db]
        sens_rows.append(sensitivity_fit(clean_imp, clean_d.twa_neq >= .02, db, spec, "S2_EXCLUDE_NEE_LT_0_02"))
        sens_rows.append(sensitivity_fit(clean_imp, clean_d.active_prop >= .75, db, spec, "S3_ACTIVE_PROP_GE_75"))
        if db == "mimic":
            strict = clean_d.uo_distinct_times >= 2
        else:
            strict = (clean_d.uo_timepoints >= 2) & (clean_d.max_entry_lag_min <= 60)
        sens_rows.append(sensitivity_fit(clean_imp, strict, db, spec, "S4_STRICT_UO_MEASUREMENT"))
        preloop = ~clean_d[("loop_pre6" if db == "mimic" else "loop_pre6h_proxy")]
        sens_rows.append(sensitivity_fit(clean_imp, preloop, db, spec, "S5_EXCLUDE_PRE_T0_LOOP_DIURETIC"))
        if db == "mimic":
            sens_rows.append(sensitivity_fit(clean_imp, pd.Series(True, index=clean_d.index), db, spec,
                                             "S6_HARMONIZED_INHOSPITAL_MORTALITY", outcome_col="death28_inhospital"))
        else:
            for suffix, ratio_col, nee_col in [
                ("CAP60", "scaled_uo_neq_cap60", "twa_neq_cap60"),
                ("CAP360", "scaled_uo_neq_cap360", "twa_neq_cap360"),
                ("NO_TERMINAL_CAP240", "scaled_uo_neq_no_terminal_cap240", "twa_neq_no_terminal_cap240")]:
                valid = clean_d[ratio_col].notna() & (clean_d[nee_col] > 0)
                sens_rows.append(sensitivity_fit(clean_imp, valid, db, spec, f"S7_{suffix}", ratio_col, nee_col))
            coverage = pd.read_csv(QC / "hospital_measurement_coverage_eicu.csv")
            high_ids = set(coverage.loc[boolify(coverage.high_measurement_coverage_hospital), "hospitalid"].astype(int))
            sens_rows.append(sensitivity_fit(clean_imp, clean_d.hospitalid.astype(int).isin(high_ids), db, spec,
                                             "HIGH_MEASUREMENT_COVERAGE_HOSPITALS"))
        sens_rows.append(sensitivity_fit(mi_ext[db], pd.Series(True, index=mi_ext[db][0].index), db, spec, "S8_SEVERITY_COMPONENT_TIMING_UNVERIFIED", extended=True))
    sens = pd.DataFrame(sens_rows)
    sens.to_csv(SENS / "sensitivity_results.csv", index=False)

    try:
        ri = random_intercept_sensitivity(mi_core["eicu"][0], spec)
    except Exception as exc:
        ri = {"status": "FAILED", "error": str(exc)}
        warning_messages.append(f"Random-intercept hospital sensitivity failed: {exc}")
    (SENS / "eicu_random_intercept_hospital.json").write_text(json.dumps(ri, indent=2), encoding="utf-8")

    t1 = pd.concat([table1_long(mimic, "MIMIC-IV"), table1_long(eicu, "eICU")], ignore_index=True)
    t1.to_csv(TABLES / "Table1.csv", index=False)
    table2 = standardized.merge(primary[["database", "overall_p", "nonlinearity_p", "or_per_1sd_lower_asinh_ratio", "or_ci_low", "or_ci_high"]], on="database", how="left")
    table2.to_csv(TABLES / "Table2.csv", index=False)
    comp_all.to_csv(TABLES / "Table3.csv", index=False)

    curves = pd.concat([curve_source(primary_fits["mimic"], mi_core["mimic"], "mimic", spec),
                        curve_source(primary_fits["eicu"], mi_core["eicu"], "eicu", spec)], ignore_index=True)
    curves.to_csv(FIGS / "Figure3_source_data.csv", index=False)
    surfaces = pd.concat([surface_source(comp_fits["mimic"]["M3"], mi_core["mimic"], "mimic", spec),
                          surface_source(comp_fits["eicu"]["M3"], mi_core["eicu"], "eicu", spec)], ignore_index=True)
    surfaces.to_csv(FIGS / "Figure2_source_data.csv", index=False)
    cohort_counts = {
        "MIMIC-IV": {"ratio_n": len(mimic), "clean_n": int(mimic.clean_cohort.sum()), "model_n": len(mimic_clean)},
        "eICU": {"ratio_n": len(eicu), "clean_n": int(eicu.clean_cohort.sum()), "model_n": len(eicu_clean)},
    }
    save_figures(curves, surfaces, comp_all, boot_all, cohort_counts)

    missing_rows = []
    for dbn, d in [("MIMIC-IV", mimic_clean), ("eICU", eicu.loc[eicu.clean_cohort])]:
        for col in ["death28", "baseline_creatinine", "map_pre_t0", "lactate_pre_t0"] + (["pre_t0_sepsis_sofa"] if dbn == "MIMIC-IV" else []):
            missing_rows.append({"database": dbn, "variable": col, "n": len(d), "missing_n": int(d[col].isna().sum()), "missing_percent": 100*d[col].isna().mean()})
    pd.DataFrame(missing_rows).to_csv(QC / "missingness_formal.csv", index=False)

    summary = {
        "mimic_model_n": len(mimic_clean), "mimic_deaths": int(mimic_clean.death28.sum()),
        "eicu_frozen_clean_n": int(eicu.clean_cohort.sum()), "eicu_model_n": len(eicu_clean),
        "eicu_outcome_missing_clean_n": int((eicu.clean_cohort & eicu.death28.isna()).sum()),
        "eicu_deaths": int(eicu_clean.death28.sum()),
        "knots_asinh_ratio": spec["ratio_knots_asinh"], "reference_scaled_ratio": spec["reference_scaled_ratio"],
        "primary": primary.to_dict(orient="records"), "standardized": standardized.to_dict(orient="records"),
        "component": comp_all.to_dict(orient="records"), "bootstrap_deltas": boot_all.to_dict(orient="records"),
        "random_intercept_hospital": ri,
        "analysis_boundary": "Associational/prognostic phenotype; no causal treatment effect, no data-derived cutoff.",
    }
    (DECISION / "formal_results_machine_readable.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")

    session = {
        "python": sys.version, "platform": platform.platform(), "numpy": np.__version__, "pandas": pd.__version__,
        "scipy": scipy.__version__, "statsmodels": sm.__version__, "sklearn": sklearn.__version__,
        "matplotlib": matplotlib.__version__, "seed": SEED,
    }
    (AUDIT / "session_info.txt").write_text("\n".join(f"{k}: {v}" for k, v in session.items()) + "\n", encoding="utf-8")
    (AUDIT / "warnings.log").write_text("\n".join(warning_messages) + ("\n" if warning_messages else "NONE\n"), encoding="utf-8")
    print(json.dumps({"status": "FORMAL_ANALYSIS_COMPLETE", "mimic_n": len(mimic_clean),
                      "eicu_n": len(eicu_clean), "outputs": len(list(PKG.rglob('*')))}, indent=2))


if __name__ == "__main__":
    with warnings.catch_warnings(record=True) as caught:
        warnings.simplefilter("always")
        main()
        if caught:
            existing = (AUDIT / "warnings.log").read_text(encoding="utf-8") if (AUDIT / "warnings.log").exists() else ""
            (AUDIT / "warnings.log").write_text(existing + "\n".join(str(w.message) for w in caught) + "\n", encoding="utf-8")
