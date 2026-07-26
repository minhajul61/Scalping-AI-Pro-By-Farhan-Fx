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
