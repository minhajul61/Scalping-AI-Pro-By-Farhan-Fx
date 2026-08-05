"""Faithful Python port of the EA's own basket/DCA/cycle logic
(ManageBasketEntries/OpenLeg/NextLotSize/GetCurrentDcaDistance/
GetBaseProfitTarget/GetEffectiveProfitTarget in
"Scalping Ai Pro By Farhan FX.mq5"), replayed bar-by-bar over historical
M1 data with the features already computed by feature_engineering.py.

BUY and SELL sides are simulated with **entirely independent state** and
their own explicit adverse-move conditions (mirroring the EA's own
`if(side==SIDE_BUY)...else...` branches) - never derived by mirroring one
side's outcome onto the other. See settings.py for the documented,
explicit simplifications (no daily self-tuner drift, no intraday brake,
no real bid/ask spread).

Output: two DataFrames.
  - `entries`: one row per bootstrap/DCA-add DECISION the live EA would
    have made, with full context features, tagged with an `episode_id`.
  - `episodes`: one row per basket "episode" (bootstrap through eventual
    close, or still-open/censored at data end), with the outcome info
    needed for labeling (Phase 4).
"""
from dataclasses import dataclass, field

import numpy as np
import pandas as pd

from config import settings


@dataclass
class _BasketState:
    leg_count: int = 0
    total_lots: float = 0.0
    weighted_avg_entry: float = 0.0
    last_leg_entry: float = 0.0
    last_leg_lots: float = 0.0
    last_leg_time: pd.Timestamp = None
    bootstrap_time: pd.Timestamp = None
    episode_id: int = -1


def _next_lot_size(leg_index, previous_lots, initial_lot, multiplier):
    raw = initial_lot * (multiplier ** leg_index)
    lots = round(raw / settings.EA_LOT_STEP) * settings.EA_LOT_STEP
    # Rounding can collapse two consecutive legs to the same step - guarantee
    # monotonic martingale growth anyway, exactly like NextLotSize() does.
    if leg_index > 0 and lots <= previous_lots:
        lots = previous_lots + settings.EA_LOT_STEP
    lots = max(settings.EA_MIN_LOT, min(settings.EA_MAX_LOT, lots))
    return round(lots, 2)


def _classify_regime(trend_pctile, vol_pctile):
    if trend_pctile >= settings.EA_REGIME_TREND_PERCENTILE:
        return "TRENDING"
    if vol_pctile >= settings.EA_REGIME_VOL_PERCENTILE:
        return "VOLATILE"
    return "RANGING"


def _regime_dca_distance_mult(regime):
    if regime == "TRENDING":
        return settings.EA_REGIME_TRENDING_DCA_MULT
    if regime == "RANGING":
        return settings.EA_REGIME_RANGING_DCA_MULT
    return 1.0  # VOLATILE: distance untouched, lot multiplier is capped instead


def _regime_lot_multiplier_cap(regime):
    if regime == "VOLATILE":
        return settings.EA_REGIME_VOLATILE_LOT_CAP
    return 999.0


def _is_atr_spiking(atr_series, i, baseline_bars):
    """Mirrors IsAtrSpiking(): current M1 ATR(14) vs the mean of the prior
    baseline_bars ATR values (shift 1..baseline_bars, never the current
    bar) - a volatility-spike "news proxy"."""
    if i < baseline_bars + 1:
        return False
    window = atr_series[i - baseline_bars: i]  # prior baseline_bars values, excluding current
    baseline = np.nanmean(window)
    current = atr_series[i - 1]  # last fully closed M1 bar, matching CopyBuffer shift=1
    if baseline <= 0 or np.isnan(baseline) or np.isnan(current):
        return False
    return current > baseline * settings.EA_MAX_ATR_RATIO


def _get_effective_profit_target(base_target, leg_count, cycle_len, last_leg_time, current_time):
    completed_cycles = leg_count // cycle_len if cycle_len > 0 else 0
    target = base_target * (1.0 + completed_cycles * settings.EA_CYCLE_TARGET_GROWTH)

    if leg_count < cycle_len or last_leg_time is None:
        return target

    hours_stuck = (current_time - last_leg_time).total_seconds() / 3600.0
    if hours_stuck <= settings.EA_STUCK_BASKET_HOURS:
        return target

    decay_hours = max(settings.EA_STUCK_BASKET_DECAY_HOURS, 0.01)
    progress = min((hours_stuck - settings.EA_STUCK_BASKET_HOURS) / decay_hours, 1.0)
    eased = target - (target - settings.EA_STUCK_BASKET_TARGET_FLOOR) * progress
    return max(eased, settings.EA_STUCK_BASKET_TARGET_FLOOR)


def simulate(df, cycle_len=None, initial_lot=None, lot_multiplier=None,
             dca_distance_usd=None, base_target=None, absolute_max_legs=None,
             use_trend_filter=True, use_atr_spike_filter=True, use_regime=True,
             atr_period=None, atr_baseline_bars=None):
    """df must already have columns: time, close, h1_trend_sign,
    d1_trend_pctile, d1_vol_pctile (from feature_engineering.build_all_features).
    Walks the full series once, simulating BUY and SELL sides independently.

    Returns (entries_df, episodes_df).
    """
    cycle_len = cycle_len or settings.EA_MAX_LEGS_PER_CYCLE
    initial_lot = initial_lot or settings.EA_INITIAL_LOT
    lot_multiplier = lot_multiplier or settings.EA_LOT_MULTIPLIER
    dca_distance_usd = dca_distance_usd or settings.EA_DCA_DISTANCE_USD
    base_target = base_target or settings.EA_BASE_PROFIT_TARGET_USD
    absolute_max_legs = absolute_max_legs or settings.EA_ABSOLUTE_MAX_LEGS
    atr_period = atr_period or settings.EA_ATR_PERIOD
    atr_baseline_bars = atr_baseline_bars or settings.EA_ATR_BASELINE_BARS

    df = df.sort_values("time").reset_index(drop=True)
    times = df["time"].to_numpy()
    closes = df["close"].to_numpy()
    trend_signs = df["h1_trend_sign"].to_numpy()
    trend_pctiles = df["d1_trend_pctile"].to_numpy()
    vol_pctiles = df["d1_vol_pctile"].to_numpy()

    # M1 ATR(14) for the spike filter - simple rolling mean of (high-low),
    # matching the sibling project's convention (close enough for a
    # spike-ratio-vs-baseline test; exact Wilder ATR isn't needed here since
    # both current and baseline use the same estimator, so the ratio is
    # robust to which reasonable ATR estimator is used).
    atr_m1 = (df["high"] - df["low"]).rolling(atr_period).mean().to_numpy()

    entries_rows = []
    episodes_rows = []
    next_episode_id = 0

    states = {"BUY": _BasketState(), "SELL": _BasketState()}

    def close_episode(sideName, t, price, reason):
        st = states[sideName]
        duration_h = (t - st.bootstrap_time).total_seconds() / 3600.0
        since_last_leg_h = (t - st.last_leg_time).total_seconds() / 3600.0
        is_stuck = (st.leg_count >= cycle_len) and (since_last_leg_h > settings.EA_STUCK_BASKET_HOURS)
        episodes_rows.append(dict(
            episode_id=st.episode_id, side=sideName,
            bootstrap_time=st.bootstrap_time, close_time=t, close_reason=reason,
            final_leg_count=st.leg_count, final_total_lots=st.total_lots,
            final_cycles=st.leg_count // cycle_len if cycle_len > 0 else 0,
            duration_hours=duration_h, hours_since_last_leg_at_close=since_last_leg_h,
            is_stuck=is_stuck, censored=False,
        ))
        states[sideName] = _BasketState()

    n = len(df)
    for i in range(n):
        t = pd.Timestamp(times[i])
        price = closes[i]
        trend_sign = trend_signs[i]
        regime = _classify_regime(trend_pctiles[i], vol_pctiles[i]) if use_regime else "RANGING"
        dca_distance = dca_distance_usd * (_regime_dca_distance_mult(regime) if use_regime else 1.0)
        atr_spiking = _is_atr_spiking(atr_m1, i, atr_baseline_bars) if use_atr_spike_filter else False
        lot_mult_cap = _regime_lot_multiplier_cap(regime) if use_regime else 999.0
        effective_multiplier = min(lot_multiplier, lot_mult_cap)

        for sideName, sign in (("BUY", 1), ("SELL", -1)):
            st = states[sideName]

            if st.leg_count == 0:
                against_trend = (trend_sign == -1) if sideName == "BUY" else (trend_sign == 1)
                if use_trend_filter and against_trend:
                    continue
                lots = _next_lot_size(0, 0.0, initial_lot, effective_multiplier)
                next_episode_id += 1
                st.episode_id = next_episode_id
                st.leg_count = 1
                st.total_lots = lots
                st.weighted_avg_entry = price
                st.last_leg_entry = price
                st.last_leg_lots = lots
                st.last_leg_time = t
                st.bootstrap_time = t
                entries_rows.append(dict(
                    episode_id=st.episode_id, side=sideName, time=t, event_type="bootstrap",
                    leg_index=0, leg_count_before=0, completed_cycles_before=0,
                    lots=lots, price=price, floating_pl_before=0.0,
                    hours_since_bootstrap=0.0, hours_since_last_leg=0.0,
                    regime=regime, dca_distance_in_effect=dca_distance,
                    is_against_trend_now=against_trend, is_atr_spiking_now=atr_spiking,
                ))
                continue

            # legCount > 0: check exit first (mirrors ManageBasketExits running
            # before ManageBasketEntries in the EA's own OnTick order... in
            # fact the EA checks exits and entries as separate passes each
            # tick; order doesn't matter here since both conditions use the
            # same snapshot price for this bar).
            floating_pl = sign * (price - st.weighted_avg_entry) * st.total_lots * 100.0
            target = _get_effective_profit_target(base_target, st.leg_count, cycle_len, st.last_leg_time, t)

            if floating_pl >= target:
                close_episode(sideName, t, price, "target_hit")
                continue

            if st.leg_count >= absolute_max_legs:
                continue  # at the hard safety ceiling, nothing left to do but wait

            adverse = (price <= st.last_leg_entry - dca_distance) if sideName == "BUY" \
                else (price >= st.last_leg_entry + dca_distance)
            if not adverse:
                continue

            if use_atr_spike_filter and atr_spiking:
                continue
            against_trend = (trend_sign == -1) if sideName == "BUY" else (trend_sign == 1)
            if use_trend_filter and against_trend:
                continue

            leg_index = st.leg_count % cycle_len
            lots = _next_lot_size(leg_index, st.last_leg_lots, initial_lot, effective_multiplier)
            completed_cycles_before = st.leg_count // cycle_len
            hours_since_bootstrap = (t - st.bootstrap_time).total_seconds() / 3600.0
            hours_since_last_leg = (t - st.last_leg_time).total_seconds() / 3600.0

            entries_rows.append(dict(
                episode_id=st.episode_id, side=sideName, time=t, event_type="dca_add",
                leg_index=leg_index, leg_count_before=st.leg_count, completed_cycles_before=completed_cycles_before,
                lots=lots, price=price, floating_pl_before=floating_pl,
                hours_since_bootstrap=hours_since_bootstrap, hours_since_last_leg=hours_since_last_leg,
                regime=regime, dca_distance_in_effect=dca_distance,
                is_against_trend_now=against_trend, is_atr_spiking_now=atr_spiking,
            ))

            new_total = st.total_lots + lots
            st.weighted_avg_entry = (st.weighted_avg_entry * st.total_lots + price * lots) / new_total
            st.total_lots = new_total
            st.leg_count += 1
            st.last_leg_entry = price
            st.last_leg_lots = lots
            st.last_leg_time = t

    # Any basket still open at data end is censored - recorded, but the
    # labeling step (Phase 4) must drop these, never force a label.
    last_time = pd.Timestamp(times[-1])
    last_price = closes[-1]
    for sideName in ("BUY", "SELL"):
        st = states[sideName]
        if st.leg_count > 0:
            duration_h = (last_time - st.bootstrap_time).total_seconds() / 3600.0
            since_last_leg_h = (last_time - st.last_leg_time).total_seconds() / 3600.0
            episodes_rows.append(dict(
                episode_id=st.episode_id, side=sideName,
                bootstrap_time=st.bootstrap_time, close_time=last_time, close_reason="censored_at_data_end",
                final_leg_count=st.leg_count, final_total_lots=st.total_lots,
                final_cycles=st.leg_count // cycle_len if cycle_len > 0 else 0,
                duration_hours=duration_h, hours_since_last_leg_at_close=since_last_leg_h,
                is_stuck=(st.leg_count >= cycle_len and since_last_leg_h > settings.EA_STUCK_BASKET_HOURS),
                censored=True,
            ))

    entries_df = pd.DataFrame(entries_rows)
    episodes_df = pd.DataFrame(episodes_rows)
    return entries_df, episodes_df
