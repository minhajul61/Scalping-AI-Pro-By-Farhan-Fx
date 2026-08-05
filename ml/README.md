# ML Research for "Scalping Ai Pro By Farhan FX"

A machine-learning research effort layered on top of the native MQL5 EA in
this repo's parent folder. **This does not fix the EA's fundamental risk
profile** — every stop-loss is off and DCA legs double in size per the
explicit, already-documented decision in the parent project's `README.md`/
`learnings.md` (2026-07-31). That is fixed, not something this project
revisits.

What this project actually does: replace two rule-based heuristics in the
EA (a simple MA+ATR trend filter, and hand-set DCA/lot-sizing thresholds)
with two properly trained, validated models, run live via MT5's ONNX
inference support (`OnnxCreate`/`OnnxRun`, confirmed supported in this
terminal build 6090).

## Two models

1. **Trend-continuation** — predicts P(the current H1 trend continues vs
   reverses/chops). Feeds into the EA's `IsAgainstTrend()` as an ensemble:
   can only make entries *more* conservative than the existing rule, never
   less.
2. **Stuck-basket-risk** — predicts P(this DCA leg-add leads to the EA's
   known catastrophic failure mode: a basket that keeps adding legs for
   many cycles/hours without ever hitting target, because there's no SL to
   stop it). Feeds into `EffectiveLotMultiplier()` to skip/shrink risky
   leg-adds.

Both are **additive/veto-only** on top of the existing rule-based system
(never replace it outright), and both ship **off by default**
(`InpUseMLTrendFilter=false`, `InpUseMLStuckRiskFilter=false`) until
backtested against the EA's own documented baselines.

## Actual results (2026-08-05 — see learnings.md for the full story)

- **Trend-continuation model: NOT shipped.** No horizon (30/60/120min) or
  model type cleared a meaningfully-above-chance holdout AUC (all landed
  at 0.49-0.51, i.e. at or below chance) — an honest negative result that
  directly matches the sibling project's own conclusion on raw direction
  prediction. Not exported to ONNX, not wired into the EA.
- **Stuck-basket-risk model: shipped (gated behind `InpUseMLStuckRiskFilter=false`
  by default).** Holdout AUC **0.81** on 526 genuinely held-out episodes —
  a real signal. Exported to ONNX (109KB, numerically validated against
  the source model to 8.96e-08) and wired into `ManageBasketEntries()`/
  `EffectiveLotMultiplier()` in the EA. **Runtime-verified in the real MT5
  Strategy Tester (2026-08-06)** — two real bugs found and fixed (model
  file needs `ONNX_COMMON_FOLDER`, not the per-agent sandbox that gets
  wiped every run; `OnnxSetOutputShape()` was missing for both outputs).
  Backtested ML ON vs OFF on the same $10,000/real-tick week: net loss
  roughly halved (-$4,712.71 -> -$2,461.29), PF 0.61 -> 0.71, drawdown cut
  18-31 percentage points, shorter losing streaks — a genuine, verified
  improvement (though one metric, largest single loss, got worse, and the
  EA is still net-negative overall given the no-SL/2.0x-multiplier
  configuration ML doesn't touch). Full story in `learnings.md`.

## Why this might not work — stated upfront (written before training)

A sibling project (`E:\Scalping AI Pro By Farhan Fx`) already spent serious
effort trying to ML-predict raw XAUUSD direction on this same broker/
account and found **no edge** — accuracy landed at ~50.4-50.7%,
indistinguishable from a coin flip, across RandomForest and LightGBM, after
a proper chronological holdout (not just a lucky 70/30 split). See that
project's `learnings.md` for the full story, including two real backtest-
methodology bugs (overlapping-trade double counting; long/short barrier-
mismatch) that had inflated an early "good-looking" result before being
caught.

This project's two targets are deliberately reframed to be more tractable
than raw direction (see `learnings.md` for the reasoning), but the honest
prior odds, stated before any training run: trend-continuation model
clearing "beats the existing simple rule" on genuine holdout ~15-30%;
stuck-basket-risk model reaching a trustworthy trained classifier ~10-20%
(the positive class — genuine multi-cycle stuck episodes — is rare by
construction, likely fewer independent examples than the sibling project's
own already-inconclusive ~700-event attempt). A pre-registered go/no-go
data-sufficiency gate exists specifically so "not enough data to train
this" is reported as a legitimate result, not hidden behind an overfit
number.

## Pipeline (see `learnings.md` for what actually happened at each step)

```
scripts/run_fetch.py            -> data/raw/*.csv (M1, H1, D1)
scripts/run_replay_and_label.py -> data/processed/*.parquet (both label sets)
scripts/run_train_trend.py      -> models/trend_continuation/<version>/
scripts/run_train_stuck.py      -> models/stuck_basket_risk/<version>/
scripts/run_export_onnx.py      -> models/*/<version>/model.onnx
scripts/run_validate_onnx.py    -> confirms ONNX output matches source model
scripts/run_backtest_compare.py -> re-runs the EA's own documented Strategy
                                    Tester windows with ML flags OFF vs ON
```

## Setup

```
cd "E:\XAUUSD Dual Basket DCA EA\ml"
"C:\Users\BeingPe\AppData\Local\Python\bin\python.exe" -m pip install -r requirements.txt
```

`config/settings.py` is the single source of truth for every tunable
parameter, including a hand-maintained mirror of the live EA's current
parameters (lot multiplier, DCA distance, cycle length, etc.) — **there is
no automated import from the `.mq5` file**; if the EA's defaults change,
this file must be updated by hand or the training data will silently
diverge from what the EA actually does live.
