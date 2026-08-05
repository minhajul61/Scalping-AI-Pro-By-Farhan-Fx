"""Train + validate the trend-continuation model.

Benchmarks against the EXISTING RULE itself (not just majority class): the
rule's own implicit "accuracy" is just how often continuation actually
happens when the rule fires (the positive rate) - it has no notion of
confidence, it just acts whenever sign != 0. A model only earns a place in
the EA if it clearly beats that bar on GENUINELY UNTOUCHED holdout data,
matching the standard the sibling project's raw-direction attempt failed
to clear.
"""
import sys
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT_DIR))
sys.path.insert(0, str(ROOT_DIR / "src"))

import json
import joblib
import numpy as np
import pandas as pd
from sklearn.ensemble import RandomForestClassifier
from sklearn.linear_model import LogisticRegression
from lightgbm import LGBMClassifier

from config import settings
from dca_ml.features.feature_engineering import ALL_FEATURE_COLS
from dca_ml.modeling.train import chronological_split, evaluate_binary
from dca_ml.util.logging_setup import get_logger

log = get_logger("train_trend_model")

MODEL_BUILDERS = {
    "logistic": lambda: LogisticRegression(**settings.LOGISTIC_PARAMS),
    "random_forest": lambda: RandomForestClassifier(**settings.RANDOM_FOREST_PARAMS),
    "lightgbm": lambda: LGBMClassifier(**settings.LIGHTGBM_PARAMS),
}


def _prep_xy(df, label_col):
    sub = df.dropna(subset=ALL_FEATURE_COLS + [label_col])
    X = sub[ALL_FEATURE_COLS]
    y = sub[label_col].astype(int)
    return sub, X, y


def train_and_validate(df, horizon):
    label_col = f"label_trend_{horizon}"
    sub, X, y = _prep_xy(df, label_col)
    log.info(f"[H={horizon}] {len(sub)} usable rows after dropping NaN features/labels")

    train_df, val_df, holdout_df = chronological_split(sub, "time", settings.CHRONOLOGICAL_SPLIT)
    log.info(f"[H={horizon}] split sizes: train={len(train_df)} val={len(val_df)} holdout={len(holdout_df)}")

    rule_baseline_val = float(val_df[label_col].mean())
    rule_baseline_holdout = float(holdout_df[label_col].mean())
    log.info(f"[H={horizon}] rule baseline (blind continuation rate): "
             f"val={rule_baseline_val:.4f} holdout={rule_baseline_holdout:.4f}")

    val_results = {}
    fitted = {}
    for name, build in MODEL_BUILDERS.items():
        model = build()
        model.fit(train_df[ALL_FEATURE_COLS], train_df[label_col].astype(int))
        val_prob = model.predict_proba(val_df[ALL_FEATURE_COLS])[:, 1]
        metrics = evaluate_binary(val_df[label_col].astype(int), val_prob)
        val_results[name] = metrics
        fitted[name] = model
        log.info(f"[H={horizon}] {name} VAL: {metrics}")

    # Pick the best on VALIDATION only (by AUC) - holdout is touched exactly
    # once, after this choice is locked in.
    best_name = max(val_results, key=lambda k: val_results[k].get("auc", 0.0))
    best_model = fitted[best_name]
    log.info(f"[H={horizon}] best on validation: {best_name} (AUC={val_results[best_name].get('auc'):.4f})")

    holdout_prob = best_model.predict_proba(holdout_df[ALL_FEATURE_COLS])[:, 1]
    holdout_metrics = evaluate_binary(holdout_df[label_col].astype(int), holdout_prob)
    log.info(f"[H={horizon}] {best_name} HOLDOUT (touched once): {holdout_metrics}")

    # "Beats the rule" check: does the model's calibrated confidence, used
    # as a threshold filter (only trust the rule when model_prob > 0.5),
    # produce a HIGHER realized continuation rate on holdout than the
    # rule's own blind baseline?
    holdout_filtered_rate = float(holdout_df.loc[holdout_prob > 0.5, label_col].mean()) \
        if (holdout_prob > 0.5).any() else float("nan")
    rate_beats_rule = (not np.isnan(holdout_filtered_rate)) and (holdout_filtered_rate > rule_baseline_holdout)
    # Same 0.55 "meaningfully above chance" bar used for the stuck-risk model
    # (see train_stuck_model.py) - required for consistency. An AUC of ~0.51
    # is not a real edge even if the filtered-rate comparison technically
    # comes out favorable on one holdout sample; this is exactly the kind of
    # marginal, noise-level result the sibling project already learned not
    # to trust (see that project's learnings.md).
    auc_meaningful = holdout_metrics.get("auc", 0.0) > 0.55
    beats_rule = rate_beats_rule and auc_meaningful
    log.info(f"[H={horizon}] holdout continuation rate when model confident (>0.5): "
             f"{holdout_filtered_rate:.4f} vs rule baseline {rule_baseline_holdout:.4f} "
             f"(rate_beats_rule={rate_beats_rule}, auc_meaningful={auc_meaningful}) -> beats_rule={beats_rule}")

    return dict(
        horizon=horizon, best_model_name=best_name, model=best_model,
        val_metrics=val_results, holdout_metrics=holdout_metrics,
        rule_baseline_val=rule_baseline_val, rule_baseline_holdout=rule_baseline_holdout,
        holdout_filtered_rate=holdout_filtered_rate, beats_rule=bool(beats_rule),
    )


def main():
    features_path = settings.DATA_PROCESSED_DIR / "trend_labeled.parquet"
    df = pd.read_parquet(features_path)
    log.info(f"Loaded {len(df)} rows from {features_path}")

    all_results = []
    for horizon in settings.TREND_LABEL_HORIZONS_MIN:
        result = train_and_validate(df, horizon)
        all_results.append(result)

    # Pick the overall winner across horizons by holdout AUC among those
    # that beat the rule; if none beat the rule, report honestly and pick
    # none as "ship-ready".
    beating = [r for r in all_results if r["beats_rule"]]
    winner = max(beating, key=lambda r: r["holdout_metrics"].get("auc", 0.0)) if beating else None

    version = "v1"
    out_dir = settings.MODELS_DIR / "trend_continuation" / version
    out_dir.mkdir(parents=True, exist_ok=True)

    summary = []
    for r in all_results:
        summary.append(dict(
            horizon=r["horizon"], best_model_name=r["best_model_name"],
            val_metrics=r["val_metrics"], holdout_metrics=r["holdout_metrics"],
            rule_baseline_val=r["rule_baseline_val"], rule_baseline_holdout=r["rule_baseline_holdout"],
            holdout_filtered_rate=r["holdout_filtered_rate"], beats_rule=r["beats_rule"],
        ))

    metadata = dict(
        results_per_horizon=summary,
        winner_horizon=(winner["horizon"] if winner else None),
        winner_model=(winner["best_model_name"] if winner else None),
        shipped=winner is not None,
        conclusion=(
            f"Model at horizon={winner['horizon']}min ({winner['best_model_name']}) "
            f"beats the existing rule on genuine holdout - candidate for shipping "
            f"(still gated behind InpUseMLTrendFilter=false by default)."
            if winner else
            "NO horizon/model combination beat the existing rule's blind continuation "
            "rate on genuine holdout. Honest result: no trained model earns a place "
            "over the current simple rule for this target, on this data. Not shipped."
        ),
    )

    with open(out_dir / "metadata.json", "w") as f:
        json.dump(metadata, f, indent=2, default=str)
    log.info(f"Saved metadata to {out_dir / 'metadata.json'}")
    log.info(metadata["conclusion"])

    if winner:
        joblib.dump(winner["model"], out_dir / "model.joblib")
        log.info(f"Saved winning model to {out_dir / 'model.joblib'}")

    return metadata


if __name__ == "__main__":
    main()
