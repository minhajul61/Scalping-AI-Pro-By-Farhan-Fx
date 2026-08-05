import sys
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT_DIR))
sys.path.insert(0, str(ROOT_DIR / "src"))

import numpy as np
import pandas as pd

from config import settings
from dca_ml.replay.basket_simulator import simulate, _next_lot_size
from dca_ml.labeling.trend_continuation_labels import add_trend_continuation_labels
from dca_ml.labeling.stuck_basket_labels import add_stuck_basket_labels
from dca_ml.util.logging_setup import get_logger

log = get_logger("run_replay_and_label")


def sanity_check_lot_sizing():
    """Regression test for the mechanical correctness of the lot-sizing/
    cycling logic itself (deviates from the plan's literal wording of
    "reproduce the exact traced 2026-07-24 incident" - that incident
    happened under a DIFFERENT EA configuration, before cycling existed
    and with a 1.5x multiplier, so it is not a like-for-like target to
    reproduce under the current 2.0x/cycling config. This directly tests
    the thing that actually matters: does NextLotSize()'s exact geometric-
    then-reset sequence come out right)."""
    seq = []
    prev = 0.0
    for global_leg in range(14):  # two full cycles of 7
        leg_index = global_leg % settings.EA_MAX_LEGS_PER_CYCLE
        lots = _next_lot_size(leg_index, prev, settings.EA_INITIAL_LOT, settings.EA_LOT_MULTIPLIER)
        seq.append(lots)
        prev = lots

    expected_cycle = [0.02, 0.04, 0.08, 0.16, 0.32, 0.64, 1.28]
    assert seq[:7] == expected_cycle, f"Cycle 1 mismatch: {seq[:7]} != {expected_cycle}"
    assert seq[7:] == expected_cycle, f"Cycle 2 (after reset) mismatch: {seq[7:]} != {expected_cycle}"
    log.info(f"Lot-sizing sanity check PASSED: {seq}")


def main():
    sanity_check_lot_sizing()

    features_path = settings.DATA_PROCESSED_DIR / "m1_with_features.parquet"
    df = pd.read_parquet(features_path)
    log.info(f"Loaded {len(df)} feature rows from {features_path}")

    entries_df, episodes_df = simulate(df)

    log.info(f"Replay produced {len(entries_df)} entry decisions, {len(episodes_df)} episodes")
    log.info(f"Episode outcomes:\n{episodes_df['close_reason'].value_counts()}")
    log.info(f"Stuck episodes: {episodes_df['is_stuck'].sum()} / {len(episodes_df)}")
    log.info(f"Entry event types:\n{entries_df['event_type'].value_counts()}")
    log.info(f"Leg-count distribution at DCA-add:\n{entries_df[entries_df.event_type=='dca_add']['leg_count_before'].value_counts().sort_index()}")

    settings.DATA_PROCESSED_DIR.mkdir(parents=True, exist_ok=True)
    entries_df.to_parquet(settings.DATA_PROCESSED_DIR / "entries.parquet", index=False)
    episodes_df.to_parquet(settings.DATA_PROCESSED_DIR / "episodes.parquet", index=False)
    log.info("Saved entries.parquet and episodes.parquet")

    # --- Label 1: trend continuation (per-bar, on the full feature set) ---
    for horizon in settings.TREND_LABEL_HORIZONS_MIN:
        df = add_trend_continuation_labels(df, horizon)
        label_col = f"label_trend_{horizon}"
        n_labeled = df[label_col].notna().sum()
        n_pos = (df[label_col] == 1.0).sum()
        log.info(f"Trend label H={horizon}min: {n_labeled} labeled rows "
                 f"({n_pos} positive, {n_labeled - n_pos} negative), "
                 f"{len(df) - n_labeled} dropped as ambiguous/no-trend")

    trend_out = settings.DATA_PROCESSED_DIR / "trend_labeled.parquet"
    df.to_parquet(trend_out, index=False)
    log.info(f"Saved {trend_out}")

    # --- Label 2: stuck-basket risk (per DCA-add decision) - go/no-go gate ---
    stuck_df, dropped_censored = add_stuck_basket_labels(entries_df, episodes_df)
    n_pos = int(stuck_df["label_stuck"].sum())
    n_total = len(stuck_df)
    log.info(f"Stuck-risk labels: {n_total} DCA-add decisions labeled "
             f"({n_pos} positive / stuck, {n_total - n_pos} negative), "
             f"{dropped_censored} dropped as censored")

    gate_floor = settings.STUCK_LABEL_MIN_POSITIVE_EVENTS
    if n_pos < gate_floor:
        log.warning(
            f"GO/NO-GO GATE: only {n_pos} positive (stuck) examples, below the "
            f"pre-registered floor of {gate_floor} - per the plan, this is a "
            f"legitimate 'insufficient data to train this model' outcome, not "
            f"something to force a fit around. Recording data_sufficiency_report "
            f"and stopping short of training Model 2 unless overridden."
        )
    else:
        log.info(f"GO/NO-GO GATE: {n_pos} positive examples clears the floor of "
                  f"{gate_floor} - proceeding to train Model 2.")

    stuck_out = settings.DATA_PROCESSED_DIR / "stuck_labeled.parquet"
    stuck_df.to_parquet(stuck_out, index=False)
    log.info(f"Saved {stuck_out}")

    import json
    report = dict(
        n_dca_add_decisions=n_total, n_positive_stuck=n_pos, n_negative=n_total - n_pos,
        n_dropped_censored=dropped_censored, gate_floor=gate_floor,
        gate_passed=bool(n_pos >= gate_floor),
    )
    (settings.MODELS_DIR / "stuck_basket_risk").mkdir(parents=True, exist_ok=True)
    report_path = settings.MODELS_DIR / "stuck_basket_risk" / "data_sufficiency_report.json"
    with open(report_path, "w") as f:
        json.dump(report, f, indent=2)
    log.info(f"Saved {report_path}")


if __name__ == "__main__":
    main()
