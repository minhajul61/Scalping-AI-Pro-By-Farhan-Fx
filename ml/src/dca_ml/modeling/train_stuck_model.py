"""Train + validate the stuck-basket-risk model.

Uses episode-grouped chronological splitting (mandatory - see
train.chronological_split_by_group's docstring): rows from the same
episode always land in the same split, since they share a strongly
correlated outcome.

Positive class (stuck episodes) is rare and low-capacity models are used
deliberately (max_depth<=3, class_weight="balanced") - a high-capacity
model would just memorize the few dozen positive episodes rather than
learn anything that generalizes.
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
from dca_ml.modeling.train import chronological_split_by_group, evaluate_binary
from dca_ml.util.logging_setup import get_logger

log = get_logger("train_stuck_model")

FEATURE_COLS = [
    "leg_count_before", "completed_cycles_before", "floating_pl_before",
    "hours_since_bootstrap", "hours_since_last_leg", "dca_distance_in_effect",
    "lots", "is_against_trend_now", "is_atr_spiking_now",
    "regime_RANGING", "regime_TRENDING", "regime_VOLATILE",
]

MODEL_BUILDERS = {
    "logistic": lambda: LogisticRegression(max_iter=1000, class_weight="balanced",
                                            random_state=settings.RANDOM_STATE),
    "shallow_rf": lambda: RandomForestClassifier(
        n_estimators=200, max_depth=settings.STUCK_MODEL_MAX_DEPTH, min_samples_leaf=5,
        class_weight="balanced", random_state=settings.RANDOM_STATE, n_jobs=-1),
    "shallow_lgbm": lambda: LGBMClassifier(
        n_estimators=200, max_depth=settings.STUCK_MODEL_MAX_DEPTH, learning_rate=0.05,
        min_child_samples=5, class_weight="balanced", random_state=settings.RANDOM_STATE, verbose=-1),
}


def _prep(df):
    df = df.copy()
    df["is_against_trend_now"] = df["is_against_trend_now"].astype(int)
    df["is_atr_spiking_now"] = df["is_atr_spiking_now"].astype(int)
    regime_dummies = pd.get_dummies(df["regime"], prefix="regime")
    for col in ("regime_RANGING", "regime_TRENDING", "regime_VOLATILE"):
        if col not in regime_dummies.columns:
            regime_dummies[col] = 0
    df = pd.concat([df, regime_dummies], axis=1)
    return df


def main():
    labeled_path = settings.DATA_PROCESSED_DIR / "stuck_labeled.parquet"
    df = pd.read_parquet(labeled_path)
    df = _prep(df)
    log.info(f"Loaded {len(df)} labeled DCA-add decisions from {labeled_path}")

    n_pos = int(df["label_stuck"].sum())
    n_episodes_pos = df.loc[df["label_stuck"] == 1, "episode_id"].nunique()
    gate_floor = settings.STUCK_LABEL_MIN_POSITIVE_EVENTS
    log.info(f"Positive examples: {n_pos} rows across {n_episodes_pos} distinct stuck episodes "
             f"(floor={gate_floor})")

    if n_pos < gate_floor:
        conclusion = (f"GO/NO-GO GATE FAILED: only {n_pos} positive examples, below the "
                       f"pre-registered floor of {gate_floor}. Not training - this is a "
                       f"legitimate, honestly-reported 'insufficient data' outcome.")
        log.warning(conclusion)
        out_dir = settings.MODELS_DIR / "stuck_basket_risk"
        out_dir.mkdir(parents=True, exist_ok=True)
        with open(out_dir / "metadata.json", "w") as f:
            json.dump(dict(shipped=False, conclusion=conclusion, n_positive=n_pos), f, indent=2)
        return

    train_df, val_df, holdout_df = chronological_split_by_group(
        df, "time", "episode_id", settings.CHRONOLOGICAL_SPLIT)
    log.info(f"Episode-grouped split: train={len(train_df)} rows/{train_df.episode_id.nunique()} episodes, "
             f"val={len(val_df)} rows/{val_df.episode_id.nunique()} episodes, "
             f"holdout={len(holdout_df)} rows/{holdout_df.episode_id.nunique()} episodes")
    log.info(f"Positive rate per split: train={train_df.label_stuck.mean():.4f} "
             f"val={val_df.label_stuck.mean():.4f} holdout={holdout_df.label_stuck.mean():.4f}")

    majority_baseline_holdout = 1.0 - float(holdout_df["label_stuck"].mean())  # accuracy of "always predict not-stuck"

    val_results = {}
    fitted = {}
    for name, build in MODEL_BUILDERS.items():
        model = build()
        model.fit(train_df[FEATURE_COLS], train_df["label_stuck"].astype(int))
        val_prob = model.predict_proba(val_df[FEATURE_COLS])[:, 1]
        metrics = evaluate_binary(val_df["label_stuck"].astype(int), val_prob)
        val_results[name] = metrics
        fitted[name] = model
        log.info(f"{name} VAL: {metrics}")

    best_name = max(val_results, key=lambda k: val_results[k].get("auc", 0.0))
    best_model = fitted[best_name]
    log.info(f"Best on validation: {best_name} (AUC={val_results[best_name].get('auc'):.4f})")

    holdout_prob = best_model.predict_proba(holdout_df[FEATURE_COLS])[:, 1]
    holdout_metrics = evaluate_binary(holdout_df["label_stuck"].astype(int), holdout_prob)
    log.info(f"{best_name} HOLDOUT (touched once): {holdout_metrics}")
    log.info(f"Majority-class (\"always not-stuck\") holdout accuracy would be: {majority_baseline_holdout:.4f}")

    beats_majority = holdout_metrics.get("auc", 0.0) > 0.55  # meaningfully above chance, not just >0.5
    conclusion = (
        f"{best_name} reaches holdout AUC={holdout_metrics.get('auc'):.4f} - "
        + ("a real, meaningfully-above-chance signal, candidate for shipping "
           "(still gated behind InpUseMLStuckRiskFilter=false by default)."
           if beats_majority else
           "not meaningfully above chance (0.55 threshold) on a genuinely held-out "
           "set of episodes never seen during training/validation. Honest result: "
           "not shipped as a trustworthy trained classifier, despite clearing the "
           "raw positive-count go/no-go floor - passing that floor means training "
           "was POSSIBLE, not that the result is trustworthy.")
    )
    log.info(conclusion)

    version = "v1"
    out_dir = settings.MODELS_DIR / "stuck_basket_risk" / version
    out_dir.mkdir(parents=True, exist_ok=True)
    metadata = dict(
        n_positive=n_pos, n_episodes_positive=n_episodes_pos,
        best_model_name=best_name, val_metrics=val_results, holdout_metrics=holdout_metrics,
        majority_baseline_holdout_accuracy=majority_baseline_holdout,
        shipped=bool(beats_majority), conclusion=conclusion,
    )
    with open(out_dir / "metadata.json", "w") as f:
        json.dump(metadata, f, indent=2, default=str)
    log.info(f"Saved metadata to {out_dir / 'metadata.json'}")

    joblib.dump(best_model, out_dir / "model.joblib")
    log.info(f"Saved model to {out_dir / 'model.joblib'} (shipped={beats_majority})")

    return metadata


if __name__ == "__main__":
    main()
