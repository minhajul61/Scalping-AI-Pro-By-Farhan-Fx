"""Shared training utilities: chronological splitting (row-level and
episode-grouped), metrics, and the benchmark-against-baseline discipline
both models must clear before being considered for shipping."""
import numpy as np
import pandas as pd
from sklearn.metrics import roc_auc_score, log_loss, brier_score_loss


def chronological_split(df, time_col, fracs=(0.6, 0.2, 0.2)):
    """Row-level chronological split - fine when each row is a reasonably
    independent decision point (the trend-continuation model)."""
    df = df.sort_values(time_col).reset_index(drop=True)
    n = len(df)
    n_train = int(n * fracs[0])
    n_val = int(n * fracs[1])
    train = df.iloc[:n_train]
    val = df.iloc[n_train:n_train + n_val]
    holdout = df.iloc[n_train + n_val:]
    return train, val, holdout


def chronological_split_by_group(df, time_col, group_col, fracs=(0.6, 0.2, 0.2)):
    """Episode-grouped chronological split - MANDATORY for the stuck-risk
    model, where multiple rows (leg-adds) share one episode's eventual
    outcome. Splitting by row instead of by episode would leak a stuck
    episode's later legs into a different split than its earlier legs -
    the same class of correlated-row leakage as the sibling project's
    overlapping-trade bug, just via groups instead of overlapping windows."""
    episode_order = (
        df.groupby(group_col)[time_col].min().sort_values().index.tolist()
    )
    n = len(episode_order)
    n_train = int(n * fracs[0])
    n_val = int(n * fracs[1])
    train_ids = set(episode_order[:n_train])
    val_ids = set(episode_order[n_train:n_train + n_val])
    holdout_ids = set(episode_order[n_train + n_val:])

    train = df[df[group_col].isin(train_ids)]
    val = df[df[group_col].isin(val_ids)]
    holdout = df[df[group_col].isin(holdout_ids)]
    return train, val, holdout


def evaluate_binary(y_true, y_prob, label=""):
    y_true = np.asarray(y_true)
    y_prob = np.asarray(y_prob)
    out = {}
    if len(np.unique(y_true)) < 2:
        out["note"] = "only one class present, AUC/log-loss undefined"
        return out
    out["auc"] = roc_auc_score(y_true, y_prob)
    out["log_loss"] = log_loss(y_true, y_prob, labels=[0, 1])
    out["brier"] = brier_score_loss(y_true, y_prob)
    out["n"] = len(y_true)
    out["positive_rate"] = float(y_true.mean())
    return out
