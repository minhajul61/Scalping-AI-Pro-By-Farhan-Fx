"""Trend-continuation labeling.

Only defined where the rule (h1_trend_sign) already says there IS a trend
(sign != 0) - this model's job is to refine an existing signal (closer to
the sibling project's "most promising" meta-labeling framing), not invent
direction from nothing (which the sibling project already tried and found
no edge in).

continuation_return = trend_sign * (close[t+H] - close[t]) / close[t]
Multiplying by sign up front (rather than computing an asymmetric long
barrier and negating it for shorts) avoids the sibling project's long/
short barrier-mismatch bug by construction - there is no asymmetric
barrier to mismatch.

Label 1 if continuation_return clears an ATR-scaled noise floor in the
trend's favor, 0 if it clears the floor against the trend, otherwise
ambiguous (dropped, never force-labeled) - same discipline as the
sibling's triple-barrier "drop ambiguous rows" rule.
"""
import numpy as np
import pandas as pd

from config import settings


def add_trend_continuation_labels(df, horizon_bars):
    """df must have columns: close, h1_trend_sign, atr_14_norm.
    Returns a copy with `continuation_return_{H}` and `label_trend_{H}` columns."""
    df = df.copy()
    close = df["close"]
    trend_sign = df["h1_trend_sign"]
    noise_floor = settings.TREND_LABEL_NOISE_FLOOR_ATR_MULT * df["atr_14_norm"]

    future_return = close.shift(-horizon_bars) / close - 1.0
    continuation_return = trend_sign * future_return

    label = pd.Series(np.nan, index=df.index)
    label[continuation_return > noise_floor] = 1.0
    label[continuation_return < -noise_floor] = 0.0
    # No trend signal at all -> not a meaningful "continuation" question -
    # excluded from this model's training set entirely, not just ambiguous.
    label[trend_sign == 0] = np.nan

    df[f"continuation_return_{horizon_bars}"] = continuation_return
    df[f"label_trend_{horizon_bars}"] = label
    return df
