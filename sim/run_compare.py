#!/usr/bin/env python3
"""Compare approximate v52 vs v53 basket rules on cached Dukascopy M1 bars.

Prints one row per variant per window. Numbers are from basket_sim.py,
not from the MT5 Strategy Tester.
"""
from __future__ import annotations

import sys
from datetime import datetime
from pathlib import Path

import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from sim.basket_sim import Config, load_frame, run_one  # noqa: E402


WINDOWS = [
    ("June", "2026-06-01", "2026-07-01"),
    ("July", "2026-07-01", "2026-08-01"),
    ("August", "2026-08-01", "2026-09-01"),
    ("Aug24-28", "2026-08-24", "2026-08-28"),
    ("Jun-Aug", "2026-06-01", "2026-09-01"),
]


def variants(comm: float) -> list[Config]:
    """v53 matches the shipped defaults: commission-aware (cap $2), Friday
    cutoff, rollover pause, ATR spike also blocks the first leg.
    Margin guard, trend widen and extreme pause are comparison-only.
    """
    base = dict(commission_per_lot_side=comm)
    out = [
        Config(name="v52", **base),
        Config(
            name="v53",
            commission_aware=True,
            commission_add_cap=2.0,
            margin_guard=False,
            friday_cutoff=True,
            rollover_pause=True,
            atr_blocks_first_leg=True,
            **base,
        ),
        Config(name="margin200", margin_guard=True, min_margin_level=200.0, max_margin_pct_of_equity=50.0, **base),
        Config(name="widen", trend_spacing=True, **base),
        Config(name="pause3", trend_spacing=True, pause_extreme=True, extreme_extend_atr=3.0, **base),
    ]
    return out


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "sim/data/days"
    comm = float(sys.argv[2]) if len(sys.argv) > 2 else 0.0
    full = load_frame(path, None, None)
    print(f"file={path} rows={len(full)} {full['time'].iloc[0]} -> {full['time'].iloc[-1]} comm/lot/side={comm}")
    # Gap check: weekday holes longer than 3 hours inside the series.
    t = pd.to_datetime(full["time"], utc=True).sort_values()
    delta = t.diff().dt.total_seconds().fillna(0)
    holes = full.loc[delta > 3 * 3600, "time"]
    print(f"gaps_over_3h={len(holes)}")
    names = sys.argv[3].split(",") if len(sys.argv) > 3 else None
    cfgs = variants(comm)
    if names:
        cfgs = [c for c in cfgs if c.name in names]
    for label, start, end in WINDOWS:
        df = load_frame(path, start, end)
        if len(df) < 100:
            print(f"\n## {label} SKIP rows={len(df)}")
            continue
        print(f"\n## {label} rows={len(df)} {df['time'].iloc[0]} -> {df['time'].iloc[-1]}")
        print("name | eqNet | closed | eqDD% | ddUSD | worstFL | maxLots | maxLegs | minML% | eqAt20 | baskets | endLots | endFL")
        for cfg in cfgs:
            t0 = datetime.now()
            r = run_one(df, cfg)
            sec = (datetime.now() - t0).total_seconds()
            at20 = f"{r.equity_at_margin_20:.0f}" if r.equity_at_margin_20 == r.equity_at_margin_20 else "never"
            print(
                f"{r.name} | {r.equity_net:.0f} | {r.closed_net:.0f} | {r.max_equity_dd_pct:.1f} | {r.max_equity_dd_usd:.0f} | "
                f"{r.worst_floating:.0f} | {r.max_buy_lots:.2f}/{r.max_sell_lots:.2f} | {r.max_legs_buy}/{r.max_legs_sell} | "
                f"{r.min_margin_level:.1f} | {at20} | {r.baskets_closed} | {r.end_buy_lots:.2f}/{r.end_sell_lots:.2f} | {r.end_floating:.0f} | {sec:.1f}s"
            )


if __name__ == "__main__":
    main()
