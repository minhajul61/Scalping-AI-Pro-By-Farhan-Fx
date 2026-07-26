# Learnings

(This file accumulates one plain-English lesson per closed trade or notable incident.
The EA's own daily self-tuner writes its automated decisions to
`MQL5/Files/GoldDualBasketDCA_tuning_log.txt` on the terminal — this file is for
human-reviewed summaries and anything the automated log wouldn't capture.)

- **2026-07-27 (visual backtest incident, no real capital involved):** Ran a
  1-week real-tick visual backtest with `InpUseDailyLimit=false` (testing
  whether the daily circuit breaker mattered) on a $2000 tester deposit,
  0.05 initial lot / 1.3x multiplier / 5 max legs / $220 basket hard-SL.
  The account was completely wiped (100%+ balance drawdown, negative
  equity, 0.03% margin level) by 46% of the way through the week, with
  2570 trades fired. The basket-level hard-SL ($220) only bounds a SINGLE
  basket's losing streak — it does nothing to stop several bad basket-SL
  hits from happening on consecutive days and compounding. The daily loss
  limit is what provides that day-to-day brake. Lesson: for this
  martingale-style EA, the daily circuit breaker is not an optional nicety
  — it is a required safety layer, and `InpUseDailyLimit` should never be
  set to `false` outside of a deliberate stress test like this one.

- **2026-07-27 (risk:reward tuning, no real capital involved):** Tried
  pyramiding (add to winners on a confirmed trend, riding the target further
  instead of closing) as a way to fix the risk:reward imbalance (avg loss
  running ~5x avg win, needing an unrealistic win rate to break even). It
  backtested WORSE (PF 0.71->0.64, win rate 78.33%->64.83%) — converting
  target-hit "sure wins" into extended, trend-riding exposure lost more
  often than it gained on this data. Reverted (`InpUsePyramid=false`).

  Went back to the two originally-proposed levers instead: lowering
  `InpBasketMaxLossUSD` (220->100, smaller realized losses) and raising
  `InpBasketProfitTargetUSD` (1.0->2.0, bigger wins) together. This worked:
  PF 0.71->0.92, long-side win rate 63.64%->78.23%, net loss
  -$108.84->-$80.76 — very close to breakeven (need ~80.7% win rate at the
  new ~1:4.2 ratio, actual is 79.34%).

  Pushed the same two levers one step further (target 2.0->2.5, max loss
  100->80) hoping to cross breakeven — this made things sharply WORSE (PF
  0.92->0.62, long-side win rate 78.23%->50.00%), not a smooth continued
  improvement. That non-monotonic result is the tell: $2.00/$100 is very
  likely a sweet spot fitted to this specific one-week dataset, not a
  genuinely robust setting. Lesson: stopped tuning here rather than
  continuing to chase breakeven on the same single week of data — the
  next real step is validating $2.00/$100 (or any further change) against
  a different time period before trusting it, not squeezing more out of
  the same backtest window.
