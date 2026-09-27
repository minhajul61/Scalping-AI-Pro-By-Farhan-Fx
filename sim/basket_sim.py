#!/usr/bin/env python3
"""Approximate M1 replay of GoldDualBasketDCA basket logic.

This is NOT an MT5 Strategy Tester run. It replays Dukascopy BID M1 bars
with a 3-segment OHLC path (bullish: open-low-high-close, bearish:
open-high-low-close), a constant spread, and no swap. Session filters use
UTC+3 as a stand-in for a typical MT5 server clock.

v52 rules mirrored from Scalping Ai Pro By Farhan FX.mq5:
  - both baskets always on
  - carryover lots: 0.01, 0.02, 0.04, then 0.08 / 0.16 / 0.32 ... cap 17
  - DCA distance = 1.2 * max(1, ATR_ratio * 1.5)
  - ATR spike (ratio > 1.5) blocks adds, not the first leg, unless the v53 flag is on
  - flat $1 gross target (POSITION_PROFIT + swap; commission excluded)
  - 5 second minimum between legs
  - new entries only from 04:30 server time
  - no stop-loss and no forced broker stop-out. Margin level is diagnostic.
    equity_at_margin_20 records the equity the first time that level
    crosses under 20%; the replay keeps trading after that.

Point value assumption: 1.00 lot gains $100 per $1 price move (100 oz).
"""
from __future__ import annotations

import argparse
import math
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path

import numpy as np
import pandas as pd

POINT_VALUE = 100.0  # USD per $1 move per 1.00 lot
SERVER_SHIFT_H = 3


@dataclass
class Leg:
    entry: float
    lots: float
    time: datetime


@dataclass
class Basket:
    legs: list[Leg] = field(default_factory=list)

    @property
    def leg_count(self) -> int:
        return len(self.legs)

    @property
    def total_lots(self) -> float:
        return sum(l.lots for l in self.legs)

    @property
    def last(self) -> Leg | None:
        return self.legs[-1] if self.legs else None

    def avg(self) -> float:
        lots = self.total_lots
        if lots <= 0:
            return 0.0
        return sum(l.entry * l.lots for l in self.legs) / lots


@dataclass
class Config:
    name: str
    initial_lot: float = 0.01
    lot_multiplier: float = 2.0
    max_single_leg: float = 17.0
    base_distance: float = 1.2
    adaptive: bool = True
    adaptive_mult: float = 1.5
    atr_spike: bool = True
    max_atr_ratio: float = 1.5
    atr_period: int = 14
    atr_baseline: int = 20
    target_usd: float = 1.0
    min_seconds: int = 5
    use_hours: bool = True
    start_hour: int = 4
    start_minute: int = 30
    spread: float = 0.20
    commission_per_lot_side: float = 0.0
    # v53 switches. All default off so Config() is v52.
    commission_aware: bool = False
    commission_add_cap: float = 0.0  # 0 = no cap when commission_aware is on
    atr_blocks_first_leg: bool = False
    margin_guard: bool = False
    min_margin_level: float = 200.0
    max_margin_pct_of_equity: float = 50.0
    leverage: float = 500.0
    trend_spacing: bool = False
    trend_extend_atr: float = 1.5
    trend_spacing_mult: float = 2.0
    pause_extreme: bool = False
    extreme_extend_atr: float = 3.0
    extreme_min_legs: int = 4
    friday_cutoff: bool = False
    friday_hour: int = 20
    rollover_pause: bool = False
    rollover_minutes: int = 30
    profit_trim: bool = False
    trim_min_legs: int = 6
    deposit: float = 30000.0


@dataclass
class Result:
    name: str
    start: str
    end: str
    bars: int
    closed_net: float
    final_equity: float
    equity_net: float
    max_equity_dd_pct: float
    max_equity_dd_usd: float
    worst_floating: float
    max_buy_lots: float
    max_sell_lots: float
    max_legs_buy: int
    max_legs_sell: int
    min_margin_level: float
    baskets_closed: int
    trims: int
    adds_blocked_margin: int
    adds_blocked_trend: int
    end_buy_lots: float
    end_sell_lots: float
    end_floating: float
    # First time the larger-side margin level fell under 20%. The replay
    # itself keeps trading; this only records that a typical broker
    # stop-out (this project saw them around 14-29%) would already have
    # closed the account. NaN equity means it never crossed 20%.
    equity_at_margin_20: float


def wilder_atr(high, low, close, period: int) -> np.ndarray:
    n = len(close)
    tr = np.zeros(n)
    tr[0] = high[0] - low[0]
    for i in range(1, n):
        tr[i] = max(high[i] - low[i], abs(high[i] - close[i - 1]), abs(low[i] - close[i - 1]))
    atr = np.full(n, np.nan)
    if n <= period:
        return atr
    atr[period - 1] = tr[:period].mean()
    for i in range(period, n):
        atr[i] = (atr[i - 1] * (period - 1) + tr[i]) / period
    return atr


def next_lot(leg_index: int, previous: float, cfg: Config) -> float:
    raw = cfg.initial_lot * (cfg.lot_multiplier ** leg_index)
    if cfg.max_single_leg > 0:
        raw = min(raw, cfg.max_single_leg)
    lots = round(raw / 0.01) * 0.01
    if leg_index > 0 and lots <= previous:
        lots = previous + 0.01
    return round(max(0.01, min(100.0, lots)), 2)


def next_carryover(outer_cycle: int, previous: float, cfg: Config) -> float:
    raw = 0.16 * (2.0 ** outer_cycle)
    if cfg.max_single_leg > 0:
        raw = min(raw, cfg.max_single_leg)
    lots = round(raw / 0.01) * 0.01
    if lots <= previous:
        lots = previous + 0.01
    return round(max(0.01, min(100.0, lots)), 2)


def lot_for_add(leg_count: int, previous: float, cfg: Config) -> float:
    cycle_len = 4
    pos = leg_count % cycle_len
    if pos < 3:
        return next_lot(pos, previous, cfg)
    outer = leg_count // cycle_len
    if outer == 0:
        return next_lot(pos, previous, cfg)
    return next_carryover(outer - 1, previous, cfg)


def prepare(df: pd.DataFrame, cfg: Config):
    df = df.sort_values("time").reset_index(drop=True)
    # Treat stored times as UTC.
    times_utc = pd.to_datetime(df["time"], utc=True)
    server = times_utc + pd.Timedelta(hours=SERVER_SHIFT_H)
    high = df["high"].to_numpy()
    low = df["low"].to_numpy()
    close = df["close"].to_numpy()
    open_ = df["open"].to_numpy()
    atr = wilder_atr(high, low, close, cfg.atr_period)
    ratio = np.ones(len(df))
    spike = np.zeros(len(df), dtype=bool)
    base_n = cfg.atr_baseline
    for i in range(base_n + 2, len(df)):
        current = atr[i - 1]
        window = atr[i - 1 - base_n : i - 1]
        if np.isnan(current) or np.isnan(window).any():
            continue
        baseline = window.mean()
        if baseline <= 0:
            continue
        ratio[i] = current / baseline
        spike[i] = ratio[i] > cfg.max_atr_ratio

    # H1 EMA/ATR on the server clock, using only closed hours.
    s = pd.DataFrame({"server": server, "high": high, "low": low, "close": close})
    s = s.set_index("server")
    h1 = s.resample("1h").agg({"high": "max", "low": "min", "close": "last"}).dropna()
    h1_atr = wilder_atr(h1["high"].to_numpy(), h1["low"].to_numpy(), h1["close"].to_numpy(), 14)
    closes = h1["close"].to_numpy()
    ema = np.full(len(h1), np.nan)
    alpha = 2.0 / (50 + 1)
    if len(closes):
        ema[0] = closes[0]
        for i in range(1, len(closes)):
            ema[i] = alpha * closes[i] + (1 - alpha) * ema[i - 1]
    h1 = h1.copy()
    h1["atr"] = h1_atr
    h1["ema"] = ema
    # Bar labeled at its OPEN. It closes one hour later. Shift so the value
    # available at time T is the last fully closed hour.
    h1_closed = h1.copy()
    h1_closed.index = h1_closed.index + pd.Timedelta(hours=1)
    aligned = h1_closed.reindex(s.index, method="ffill")
    h1_ema = aligned["ema"].to_numpy()
    h1_atr_m = aligned["atr"].to_numpy()
    return {
        "open": open_,
        "high": high,
        "low": low,
        "close": close,
        "ratio": ratio,
        "spike": spike,
        "server": pd.DatetimeIndex(server).to_pydatetime(),
        "h1_ema": h1_ema,
        "h1_atr": h1_atr_m,
    }


class Sim:
    def __init__(self, cfg: Config, data: dict):
        self.cfg = cfg
        self.data = data
        self.buy = Basket()
        self.sell = Basket()
        self.balance = cfg.deposit
        self.day_key = None
        self.day_start_balance = cfg.deposit
        self.banked_today = 0.0
        self.peak_equity = cfg.deposit
        self.max_dd = 0.0
        self.max_dd_usd = 0.0
        self.worst_floating = 0.0
        self.max_buy_lots = 0.0
        self.max_sell_lots = 0.0
        self.max_legs_buy = 0
        self.max_legs_sell = 0
        self.min_margin = math.inf
        self.closed = 0
        self.trims = 0
        self.blocked_margin = 0
        self.blocked_trend = 0
        self.equity_at_margin_20 = float("nan")
        self._cur_i = 0

    def gross(self, side: str, bid: float) -> float:
        ask = bid + self.cfg.spread
        b = self.buy if side == "BUY" else self.sell
        pl = 0.0
        for leg in b.legs:
            if side == "BUY":
                pl += (bid - leg.entry) * leg.lots * POINT_VALUE
            else:
                pl += (leg.entry - ask) * leg.lots * POINT_VALUE
        return pl

    def floating(self, bid: float) -> float:
        return self.gross("BUY", bid) + self.gross("SELL", bid)

    def equity(self, bid: float) -> float:
        return self.balance + self.floating(bid)

    def comm_for_lots(self, lots: float) -> float:
        # Negative number (a cost) per side.
        return -abs(self.cfg.commission_per_lot_side) * lots

    def net_target_gross_required(self, side: str) -> float:
        b = self.buy if side == "BUY" else self.sell
        target = self.cfg.target_usd
        if self.cfg.commission_aware and b.total_lots > 0:
            # Open commission already hit the balance. Close commission is
            # still ahead. Both must be covered before the $1 is real.
            # A cap stops a deep basket from needing tens of dollars of
            # retracement (which, on the June 2026 sample, held losers open
            # and increased drawdown).
            open_c = self.comm_for_lots(b.total_lots)
            extra = -(open_c + open_c)
            cap = self.cfg.commission_add_cap
            if cap > 0:
                extra = min(extra, cap)
            target = target + extra
        return target

    def tp_price(self, side: str) -> float | None:
        b = self.buy if side == "BUY" else self.sell
        if b.total_lots <= 0:
            return None
        dist = self.net_target_gross_required(side) / (b.total_lots * POINT_VALUE)
        if side == "BUY":
            return b.avg() + dist
        return b.avg() - dist

    def dca_distance(self, side: str, bid: float) -> float:
        cfg = self.cfg
        ratio = self.data["ratio"][self._cur_i]
        if cfg.adaptive:
            dist = cfg.base_distance * max(1.0, ratio * cfg.adaptive_mult)
        else:
            dist = cfg.base_distance
        if cfg.trend_spacing:
            ema = self.data["h1_ema"][self._cur_i]
            hatr = self.data["h1_atr"][self._cur_i]
            if ema == ema and hatr == hatr and hatr > 0:
                if side == "BUY":
                    extend = (ema - bid) / hatr
                else:
                    extend = (bid - ema) / hatr
                if extend >= cfg.trend_extend_atr:
                    dist *= cfg.trend_spacing_mult
        return dist

    def session_blocks(self, when: datetime) -> bool:
        cfg = self.cfg
        if cfg.use_hours:
            if when.hour < cfg.start_hour or (when.hour == cfg.start_hour and when.minute < cfg.start_minute):
                return True
        if cfg.friday_cutoff and when.weekday() == 4:
            if when.hour > cfg.friday_hour or (when.hour == cfg.friday_hour and when.minute >= 0):
                return True
        if cfg.rollover_pause:
            minutes = when.hour * 60 + when.minute
            if minutes >= 24 * 60 - cfg.rollover_minutes or minutes < cfg.rollover_minutes:
                return True
        return False

    def extreme_blocks(self, side: str, bid: float) -> bool:
        cfg = self.cfg
        if not cfg.pause_extreme:
            return False
        b = self.buy if side == "BUY" else self.sell
        if b.leg_count < cfg.extreme_min_legs:
            return False
        ema = self.data["h1_ema"][self._cur_i]
        hatr = self.data["h1_atr"][self._cur_i]
        if not (ema == ema and hatr == hatr and hatr > 0):
            return False
        extend = (ema - bid) / hatr if side == "BUY" else (bid - ema) / hatr
        if extend >= cfg.extreme_extend_atr:
            self.blocked_trend += 1
            return True
        return False

    def margin_blocks(self, side: str, lots: float, bid: float) -> bool:
        cfg = self.cfg
        if not cfg.margin_guard or lots <= 0:
            return False
        eq = self.equity(bid)
        if eq <= 0:
            self.blocked_margin += 1
            return True
        buy_lots = self.buy.total_lots + (lots if side == "BUY" else 0.0)
        sell_lots = self.sell.total_lots + (lots if side == "SELL" else 0.0)
        # Larger-side hedge model: the blow-ups in this project happened when
        # ONE side ran away, so margin is charged on the bigger side.
        price = max(bid, 1.0)
        margin = max(buy_lots, sell_lots) * price * POINT_VALUE / cfg.leverage
        if margin <= 0:
            return False
        level = eq / margin * 100.0
        used_pct = margin / eq * 100.0
        if (cfg.min_margin_level > 0 and level < cfg.min_margin_level) or (
            cfg.max_margin_pct_of_equity > 0 and used_pct > cfg.max_margin_pct_of_equity
        ):
            self.blocked_margin += 1
            return True
        return False

    def mark(self, bid: float):
        eq = self.equity(bid)
        fl = self.floating(bid)
        if fl < self.worst_floating:
            self.worst_floating = fl
        if eq > self.peak_equity:
            self.peak_equity = eq
        dd = self.peak_equity - eq
        if dd > self.max_dd_usd:
            self.max_dd_usd = dd
        # Percent and dollars are tracked separately. A later, larger dollar
        # hole on a bigger account must not overwrite an earlier, worse percent.
        pct = dd / self.peak_equity * 100.0 if self.peak_equity > 0 else 0.0
        if pct > self.max_dd:
            self.max_dd = pct
        self.max_buy_lots = max(self.max_buy_lots, self.buy.total_lots)
        self.max_sell_lots = max(self.max_sell_lots, self.sell.total_lots)
        self.max_legs_buy = max(self.max_legs_buy, self.buy.leg_count)
        self.max_legs_sell = max(self.max_legs_sell, self.sell.leg_count)
        buy_lots = self.buy.total_lots
        sell_lots = self.sell.total_lots
        margin = max(buy_lots, sell_lots) * max(bid, 1.0) * POINT_VALUE / self.cfg.leverage
        if margin > 0:
            level = eq / margin * 100.0
            if level < self.min_margin:
                self.min_margin = level
            if level < 20.0 and not math.isfinite(self.equity_at_margin_20):
                self.equity_at_margin_20 = eq

    def open_leg(self, side: str, lots: float, bid: float, when: datetime):
        entry = (bid + self.cfg.spread) if side == "BUY" else bid
        b = self.buy if side == "BUY" else self.sell
        b.legs.append(Leg(entry, lots, when))
        self.balance += self.comm_for_lots(lots)

    def close_basket(self, side: str, bid: float):
        b = self.buy if side == "BUY" else self.sell
        if not b.legs:
            return
        gross = self.gross(side, bid)
        close_c = self.comm_for_lots(b.total_lots)
        net = gross + close_c
        self.balance += net
        self.banked_today += net
        self.closed += 1
        if side == "BUY":
            self.buy = Basket()
        else:
            self.sell = Basket()

    def try_trim(self, bid: float, when: datetime):
        if not self.cfg.profit_trim:
            return
        if self.session_blocks(when):
            return
        for side in ("BUY", "SELL"):
            b = self.buy if side == "BUY" else self.sell
            if b.leg_count < self.cfg.trim_min_legs:
                continue
            # Furthest leg: improves the average the most per lot removed.
            if side == "BUY":
                idx = max(range(len(b.legs)), key=lambda i: b.legs[i].entry)
                leg = b.legs[idx]
                leg_gross = (bid - leg.entry) * leg.lots * POINT_VALUE
            else:
                idx = min(range(len(b.legs)), key=lambda i: b.legs[i].entry)
                leg = b.legs[idx]
                ask = bid + self.cfg.spread
                leg_gross = (leg.entry - ask) * leg.lots * POINT_VALUE
            # Open commission was taken when the leg opened. Closing pays the other side.
            # Open commission already left the balance when the leg was
            # opened. Closing only adds the gross plus the closing side.
            close_cash = leg_gross + self.comm_for_lots(leg.lots)
            if close_cash >= 0:
                continue
            realized_today = self.balance - self.day_start_balance
            if realized_today + close_cash < 0:
                continue
            self.balance += close_cash
            self.banked_today += close_cash
            del b.legs[idx]
            self.trims += 1

    def maybe_exit(self, side: str, bid: float) -> bool:
        b = self.buy if side == "BUY" else self.sell
        if b.leg_count == 0:
            return False
        if self.gross(side, bid) >= self.net_target_gross_required(side):
            self.close_basket(side, bid)
            return True
        return False

    def maybe_enter(self, side: str, bid: float, when: datetime):
        cfg = self.cfg
        if self.session_blocks(when):
            return
        b = self.buy if side == "BUY" else self.sell
        spiked = cfg.atr_spike and bool(self.data["spike"][self._cur_i])
        if b.leg_count == 0:
            if cfg.atr_blocks_first_leg and spiked:
                return
            lots = cfg.initial_lot
            if self.margin_blocks(side, lots, bid):
                return
            self.open_leg(side, lots, bid, when)
            return
        if spiked:
            return
        if self.extreme_blocks(side, bid):
            return
        last = b.last
        dist = self.dca_distance(side, bid)
        if side == "BUY":
            adverse = bid <= last.entry - dist
        else:
            adverse = (bid + cfg.spread) >= last.entry + dist
        if not adverse:
            return
        if cfg.min_seconds > 0 and (when - last.time).total_seconds() < cfg.min_seconds:
            return
        lots = lot_for_add(b.leg_count, last.lots, cfg)
        if self.margin_blocks(side, lots, bid):
            return
        self.open_leg(side, lots, bid, when)

    def tick(self, bid: float, when: datetime):
        # Exits on both sides, then entries. Mirrors OnTick order.
        self.maybe_exit("BUY", bid)
        self.maybe_exit("SELL", bid)
        self.maybe_enter("BUY", bid, when)
        self.maybe_enter("SELL", bid, when)
        self.mark(bid)

    def walk_segment(self, bid0: float, bid1: float, t0: datetime, t1: datetime):
        guard = 0
        while (t1 - t0).total_seconds() > 1e-6 and guard < 40:
            guard += 1
            span = (t1 - t0).total_seconds()
            db = bid1 - bid0

            def bid_at(t: datetime) -> float:
                a = (t - t0).total_seconds() / span
                return bid0 + db * a

            best_t = None
            best_kind = None  # ("exit"/"enter", side)
            before = (len(self.buy.legs), len(self.sell.legs), round(self.balance, 4))

            for side in ("BUY", "SELL"):
                b = self.buy if side == "BUY" else self.sell
                if b.leg_count == 0:
                    continue
                tp = self.tp_price(side)
                if tp is None:
                    continue
                if side == "BUY":
                    level = tp
                    already = bid0 >= level
                    crossing = db > 0 and bid0 < level <= bid1
                else:
                    level = tp - self.cfg.spread
                    already = bid0 <= level
                    crossing = db < 0 and bid1 <= level <= bid0
                if already:
                    t_hit = t0
                elif crossing and abs(db) > 1e-12:
                    frac = (level - bid0) / db
                    t_hit = t0 + timedelta(seconds=span * frac)
                else:
                    t_hit = None
                if t_hit is not None and (best_t is None or t_hit < best_t):
                    best_t = t_hit
                    best_kind = ("exit", side)

            for side in ("BUY", "SELL"):
                b = self.buy if side == "BUY" else self.sell
                if b.leg_count == 0:
                    if self.session_blocks(t0):
                        continue
                    if self.cfg.atr_blocks_first_leg and self.cfg.atr_spike and bool(self.data["spike"][self._cur_i]):
                        continue
                    t_hit = t0
                    if best_t is None or t_hit < best_t:
                        best_t = t_hit
                        best_kind = ("enter", side)
                    continue
                if self.cfg.atr_spike and bool(self.data["spike"][self._cur_i]):
                    continue
                if self.session_blocks(t0) and self.session_blocks(t1):
                    continue
                last = b.last
                # Distance uses the price at the moment of the add; approximate
                # with bid0 so the level is stable inside this search step.
                dist = self.dca_distance(side, bid0)
                if side == "BUY":
                    level = last.entry - dist
                    already = bid0 <= level
                    crossing = db < 0 and bid1 <= level <= bid0
                else:
                    level = last.entry + dist - self.cfg.spread
                    already = bid0 >= level
                    crossing = db > 0 and bid0 <= level <= bid1
                if already:
                    t_hit = t0
                elif crossing and abs(db) > 1e-12:
                    frac = (level - bid0) / db
                    t_hit = t0 + timedelta(seconds=span * max(0.0, min(1.0, frac)))
                else:
                    continue
                ready = last.time + timedelta(seconds=self.cfg.min_seconds)
                if t_hit < ready:
                    t_hit = ready
                    if t_hit >= t1:
                        continue
                    # Still adverse at the delayed time?
                    b_then = bid_at(t_hit)
                    if side == "BUY" and b_then > level:
                        continue
                    if side == "SELL" and b_then < level:
                        continue
                if t_hit > t1:
                    continue
                if best_t is None or t_hit < best_t or (t_hit == best_t and best_kind and best_kind[0] == "enter"):
                    if best_t is not None and t_hit == best_t and best_kind and best_kind[0] == "exit":
                        continue
                    best_t = t_hit
                    best_kind = ("enter", side)

            if best_kind is None or best_t is None or best_t >= t1 - timedelta(microseconds=1):
                self.tick_mark_only(bid1)
                return
            b_at = bid_at(best_t)
            if best_kind[0] == "exit":
                self.maybe_exit(best_kind[1], b_at)
            else:
                self.maybe_enter(best_kind[1], b_at, best_t)
            after = (len(self.buy.legs), len(self.sell.legs), round(self.balance, 4))
            self.mark(b_at)
            if after == before:
                # Gate refused the action. Stop scanning this segment so a
                # blocked bootstrap/add cannot spin until the guard trips.
                self.tick_mark_only(bid1)
                return
            # Nudge off an exact-time tie so the next search cannot refire
            # the same instant forever.
            bid0, t0 = b_at, best_t + timedelta(microseconds=1)
        self.tick_mark_only(bid1)

    def tick_mark_only(self, bid: float):
        self.mark(bid)

    def run(self) -> Result:
        d = self.data
        n = len(d["open"])
        for i in range(n):
            self._cur_i = i
            when0: datetime = d["server"][i]
            if self.day_key != when0.date():
                self.day_key = when0.date()
                self.day_start_balance = self.balance
                self.banked_today = 0.0
            o, h, l, c = d["open"][i], d["high"][i], d["low"][i], d["close"][i]
            # Skip frozen weekend prints (no range and identical neighbors are fine to keep;
            # a completely flat bar just won't add).
            if c >= o:
                path = [o, l, h, c]
            else:
                path = [o, h, l, c]
            t_cursor = when0
            step = timedelta(seconds=20)
            self.try_trim(o, when0)
            for a, b in zip(path, path[1:]):
                t_next = t_cursor + step
                self.walk_segment(a, b, t_cursor, t_next)
                t_cursor = t_next
            # Exits that the analytical search might have missed because the
            # target moved after an add in this bar: settle at the close.
            self.maybe_exit("BUY", c)
            self.maybe_exit("SELL", c)
            self.mark(c)
        end_bid = float(d["close"][-1])
        # Mark-to-market, matching a tester that still holds the baskets.
        final_eq = self.equity(end_bid)
        if not math.isfinite(self.min_margin):
            self.min_margin = math.inf
        return Result(
            name=self.cfg.name,
            start=str(d["server"][0]),
            end=str(d["server"][-1]),
            bars=n,
            closed_net=self.balance - self.cfg.deposit,
            final_equity=final_eq,
            equity_net=final_eq - self.cfg.deposit,
            max_equity_dd_pct=self.max_dd,
            max_equity_dd_usd=self.max_dd_usd,
            worst_floating=self.worst_floating,
            max_buy_lots=self.max_buy_lots,
            max_sell_lots=self.max_sell_lots,
            max_legs_buy=self.max_legs_buy,
            max_legs_sell=self.max_legs_sell,
            min_margin_level=self.min_margin if math.isfinite(self.min_margin) else float("nan"),
            baskets_closed=self.closed,
            trims=self.trims,
            adds_blocked_margin=self.blocked_margin,
            adds_blocked_trend=self.blocked_trend,
            end_buy_lots=self.buy.total_lots,
            end_sell_lots=self.sell.total_lots,
            end_floating=self.floating(end_bid),
            equity_at_margin_20=self.equity_at_margin_20,
        )


def load_days(directory: str, start: str | None, end: str | None) -> pd.DataFrame:
    """Load cached per-day parquets. A missing weekday is a gap, not a fill."""
    root = Path(directory)
    frames = []
    for path in sorted(root.glob("*.parquet")):
        day = path.stem
        if start and day < start[:10]:
            continue
        if end and day >= end[:10]:
            continue
        frames.append(pd.read_parquet(path))
    if not frames:
        return pd.DataFrame(columns=["time", "open", "high", "low", "close"])
    df = pd.concat(frames, ignore_index=True)
    df["time"] = pd.to_datetime(df["time"], utc=True)
    df = df.sort_values("time").drop_duplicates("time")
    return df.reset_index(drop=True)


def load_frame(path: str, start: str | None, end: str | None) -> pd.DataFrame:
    p = Path(path)
    if p.is_dir():
        return load_days(str(p), start, end)
    df = pd.read_parquet(path)
    df["time"] = pd.to_datetime(df["time"], utc=True)
    if start:
        df = df[df["time"] >= pd.Timestamp(start, tz="UTC")]
    if end:
        df = df[df["time"] < pd.Timestamp(end, tz="UTC")]
    return df.reset_index(drop=True)


def run_one(df: pd.DataFrame, cfg: Config) -> Result:
    data = prepare(df, cfg)
    return Sim(cfg, data).run()


def fmt(r: Result) -> str:
    return (
        f"{r.name:22} eqNet={r.equity_net:10.0f} closed={r.closed_net:10.0f} "
        f"eqDD={r.max_equity_dd_pct:6.1f}% (${r.max_equity_dd_usd:,.0f}) "
        f"worstFL={r.worst_floating:10.0f} maxLots={r.max_buy_lots:.2f}/{r.max_sell_lots:.2f} "
        f"maxLegs={r.max_legs_buy}/{r.max_legs_sell} minML={r.min_margin_level:7.1f}% "
        f"baskets={r.baskets_closed} trims={r.trims} blkM={r.adds_blocked_margin} blkT={r.adds_blocked_trend} "
        f"endLots={r.end_buy_lots:.2f}/{r.end_sell_lots:.2f} endFL={r.end_floating:.0f} "
        f"eqAt20%ML={r.equity_at_margin_20:.0f}"
    )


def variant_grid(comm: float) -> list[Config]:
    base = dict(commission_per_lot_side=comm)
    v = []
    v.append(Config(name="v52", **base))
    v.append(Config(name="v52_commAware", commission_aware=True, **base))
    v.append(Config(name="margin", margin_guard=True, **base))
    v.append(Config(name="trendWiden", trend_spacing=True, **base))
    v.append(Config(name="trendPause", trend_spacing=True, pause_extreme=True, **base))
    v.append(Config(name="fridayRoll", friday_cutoff=True, rollover_pause=True, **base))
    v.append(Config(name="atrFirst", atr_blocks_first_leg=True, **base))
    v.append(Config(name="trim", profit_trim=True, **base))
    v.append(Config(
        name="combo",
        commission_aware=True,
        margin_guard=True,
        trend_spacing=True,
        pause_extreme=True,
        friday_cutoff=True,
        rollover_pause=True,
        atr_blocks_first_leg=True,
        profit_trim=True,
        **base,
    ))
    v.append(Config(
        name="combo_noTrim",
        commission_aware=True,
        margin_guard=True,
        trend_spacing=True,
        pause_extreme=True,
        friday_cutoff=True,
        rollover_pause=True,
        atr_blocks_first_leg=True,
        profit_trim=False,
        **base,
    ))
    v.append(Config(
        name="combo_noPause",
        commission_aware=True,
        margin_guard=True,
        trend_spacing=True,
        pause_extreme=False,
        friday_cutoff=True,
        rollover_pause=True,
        atr_blocks_first_leg=True,
        profit_trim=False,
        **base,
    ))
    return v


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default="sim/data/xauusd_m1_duka.parquet")
    ap.add_argument("--start", default="2026-06-01")
    ap.add_argument("--end", default="2026-09-27")
    ap.add_argument("--comm", type=float, default=0.0)
    ap.add_argument("--names", default="")
    args = ap.parse_args()
    df = load_frame(args.data, args.start, args.end)
    print(f"bars={len(df)} {df['time'].iloc[0]} -> {df['time'].iloc[-1]} comm={args.comm}")
    cfgs = variant_grid(args.comm)
    if args.names:
        want = set(args.names.split(","))
        cfgs = [c for c in cfgs if c.name in want]
    for cfg in cfgs:
        t0 = datetime.now()
        r = run_one(df, cfg)
        dt = (datetime.now() - t0).total_seconds()
        print(f"[{dt:5.1f}s] {fmt(r)}")


if __name__ == "__main__":
    main()
