"""Feature engineering for both ML models.

Base 13-feature set is ported UNCHANGED from the sibling project's
E:\\Scalping AI Pro By Farhan Fx\\src\\scalping_ai\\features\\feature_engineering.py
(itself ported from E:\\Farhan Scalping\\ml\\train_model.py) - kept
identical so any performance difference traces to labeling/target, not a
different feature set.

The EA-specific features mirror the LIVE EA's own indicator calculations
as closely as possible (GetTrend()/UpdateMarketRegime() in
"Scalping Ai Pro By Farhan FX.mq5"), including the exact "last fully
closed bar" semantics the EA uses (CopyBuffer(..., shift=1, ...)) - never
the still-forming current bar, or these features would look ahead relative
to what the live EA can actually see at decision time.
"""
import numpy as np
import pandas as pd

FEATURE_COLS = [
    "ret_1", "ret_5", "ret_15", "ret_30",
    "ema_10_dist", "ema_50_dist",
    "rsi_14", "atr_14_norm", "bb_pos", "vol_z",
    "hour_sin", "hour_cos", "vola_15",
]

EA_FEATURE_COLS = [
    "h1_ma50_dist", "h1_atr14_norm", "h1_trend_strength", "h1_trend_sign", "h1_trend_age_bars",
    "d1_trend_pctile", "d1_vol_pctile",
]

ALL_FEATURE_COLS = FEATURE_COLS + EA_FEATURE_COLS


def _rsi(series, period=14):
    delta = series.diff()
    gain = delta.clip(lower=0).rolling(period).mean()
    loss = (-delta.clip(upper=0)).rolling(period).mean()
    rs = gain / loss.replace(0, np.nan)
    return 100 - (100 / (1 + rs))


def _true_range(df):
    high, low, close = df["high"], df["low"], df["close"]
    prev_close = close.shift(1)
    return pd.concat([
        high - low,
        (high - prev_close).abs(),
        (low - prev_close).abs(),
    ], axis=1).max(axis=1)


def _wilder_atr(df, period):
    """Standard Wilder-smoothed ATR approximation (EMA with alpha=1/period),
    matching MT5's built-in iATR closely enough for feature purposes - the
    Phase 7 MQL5-vs-Python parity test is the authoritative check, not this
    docstring."""
    tr = _true_range(df)
    return tr.ewm(alpha=1.0 / period, adjust=False, min_periods=period).mean()


def _trend_age_bars(sign_series):
    """Consecutive bars (including current) the trend sign has held."""
    changed = sign_series != sign_series.shift(1)
    group_id = changed.cumsum()
    return sign_series.groupby(group_id).cumcount() + 1


def _expanding_percentile_rank(series):
    """For each i, percentile rank of series[i] within series[0..i]
    inclusive - mirrors the EA's own PercentileRankOf(), which is
    recomputed fresh each day against the *entire* D1 history available at
    that time (an expanding window), not a fixed lookback. O(n^2) but D1
    series here is only ~1,500 bars - trivial."""
    values = series.to_numpy()
    n = len(values)
    out = np.empty(n)
    for i in range(n):
        window = values[: i + 1]
        valid = window[~np.isnan(window)]
        if len(valid) == 0 or np.isnan(values[i]):
            out[i] = np.nan
        else:
            out[i] = 100.0 * (valid <= values[i]).sum() / len(valid)
    return pd.Series(out, index=series.index)


def build_m1_base_features(df_m1):
    """The unchanged 13-feature base set, computed on M1 bars."""
    df = df_m1.sort_values("time").reset_index(drop=True).copy()
    close = df["close"]

    df["ret_1"] = close.pct_change(1)
    df["ret_5"] = close.pct_change(5)
    df["ret_15"] = close.pct_change(15)
    df["ret_30"] = close.pct_change(30)

    ema_10 = close.ewm(span=10, adjust=False).mean()
    ema_50 = close.ewm(span=50, adjust=False).mean()
    df["ema_10_dist"] = (close - ema_10) / close
    df["ema_50_dist"] = (close - ema_50) / close

    df["rsi_14"] = _rsi(close, 14)

    atr_14 = (df["high"] - df["low"]).rolling(14).mean()
    df["atr_14_norm"] = atr_14 / close

    sma20 = close.rolling(20).mean()
    std20 = close.rolling(20).std()
    df["bb_pos"] = (close - (sma20 - 2 * std20)) / (4 * std20)

    df["vol_z"] = (
        (df["tick_volume"] - df["tick_volume"].rolling(50).mean())
        / df["tick_volume"].rolling(50).std()
    )

    df["hour_sin"] = np.sin(2 * np.pi * df["time"].dt.hour / 24)
    df["hour_cos"] = np.cos(2 * np.pi * df["time"].dt.hour / 24)

    df["vola_15"] = df["ret_1"].rolling(15).std()

    return df


def build_h1_indicators(df_h1, ma_period=50, atr_period=14, trend_strength_atr_mult=0.5):
    """Mirrors GetTrend() exactly: trend_sign = 1 if close > MA+margin,
    -1 if close < MA-margin, 0 otherwise, where margin = ATR * mult."""
    df = df_h1.sort_values("time").reset_index(drop=True).copy()
    close = df["close"]

    ma = close.rolling(ma_period).mean()
    atr = _wilder_atr(df, atr_period)
    margin = atr * trend_strength_atr_mult

    df["h1_ma50_dist"] = (close - ma) / close
    df["h1_atr14_norm"] = atr / close
    df["h1_trend_strength"] = (close - ma).abs() / atr

    sign = pd.Series(0, index=df.index, dtype=int)
    sign[close > ma + margin] = 1
    sign[close < ma - margin] = -1
    df["h1_trend_sign"] = sign
    df["h1_trend_age_bars"] = _trend_age_bars(sign)

    return df


def build_d1_regime_features(df_d1, ma_period=50, atr_period=14):
    """Mirrors UpdateMarketRegime(): trend-strength and ATR ranked as an
    expanding percentile against all D1 history available up to that bar."""
    df = df_d1.sort_values("time").reset_index(drop=True).copy()
    close = df["close"]

    ma = close.rolling(ma_period).mean()
    atr = _wilder_atr(df, atr_period)
    trend_strength = (close - ma).abs() / atr

    df["d1_atr"] = atr
    df["d1_trend_strength"] = trend_strength
    df["d1_trend_pctile"] = _expanding_percentile_rank(trend_strength)
    df["d1_vol_pctile"] = _expanding_percentile_rank(atr)

    return df


def _asof_merge_last_closed_bar(df_m1, df_higher_tf, higher_tf_cols, bar_duration):
    """Joins df_higher_tf's indicator columns onto df_m1, using only the
    LAST FULLY CLOSED higher-timeframe bar as of each M1 timestamp - mirrors
    the EA's own CopyBuffer(handle, 0, shift=1, count=1, buf) semantics
    (never the still-forming current bar). Achieved by shifting the higher
    timeframe's own bar-open timestamps forward by one bar_duration before
    the as-of merge, so a bar's values only become "visible" once that bar
    has actually closed."""
    lookup = df_higher_tf[["time"] + higher_tf_cols].copy()
    lookup["visible_from"] = lookup["time"] + bar_duration
    lookup = lookup.sort_values("visible_from").reset_index(drop=True)

    m1_sorted = df_m1.sort_values("time").reset_index(drop=True)
    merged = pd.merge_asof(
        m1_sorted, lookup.drop(columns=["time"]),
        left_on="time", right_on="visible_from",
        direction="backward",
    )
    return merged.drop(columns=["visible_from"])


def build_all_features(df_m1, df_h1, df_d1):
    """End-to-end: base M1 features + EA-specific H1/D1 features, joined
    with correct last-closed-bar alignment. Returns the M1 dataframe with
    every column in ALL_FEATURE_COLS added."""
    m1 = build_m1_base_features(df_m1)
    h1 = build_h1_indicators(df_h1)
    d1 = build_d1_regime_features(df_d1)

    merged = _asof_merge_last_closed_bar(
        m1, h1,
        ["h1_ma50_dist", "h1_atr14_norm", "h1_trend_strength", "h1_trend_sign", "h1_trend_age_bars"],
        pd.Timedelta(hours=1),
    )
    merged = _asof_merge_last_closed_bar(
        merged, d1,
        ["d1_trend_pctile", "d1_vol_pctile"],
        pd.Timedelta(days=1),
    )
    return merged
