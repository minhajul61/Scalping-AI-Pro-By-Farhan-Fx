"""Stuck-basket-risk labeling.

Consumes basket_simulator.py's (entries_df, episodes_df) output. Only
`event_type == "dca_add"` rows are labeled - this model informs the DCA-add
gate specifically (ManageBasketEntries()'s adverse-move branch), not the
bootstrap entry.

Label 1 if the leg-add's episode eventually becomes "stuck" (reaches >= 1
full cycle AND stays open > InpStuckBasketHours past its last leg before
resolving), label 0 if the episode closes at target without ever meeting
that condition. Episodes still open (censored) at data end are DROPPED
entirely, never force-labeled either way - same discipline as every other
label in this project.
"""
import pandas as pd


def add_stuck_basket_labels(entries_df, episodes_df):
    dca_adds = entries_df[entries_df["event_type"] == "dca_add"].copy()

    ep = episodes_df.set_index("episode_id")
    dca_adds["episode_censored"] = dca_adds["episode_id"].map(ep["censored"])
    dca_adds["label_stuck"] = dca_adds["episode_id"].map(ep["is_stuck"]).astype(float)

    before = len(dca_adds)
    dca_adds = dca_adds[~dca_adds["episode_censored"]].copy()
    dropped = before - len(dca_adds)

    return dca_adds, dropped
