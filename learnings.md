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

- **2026-07-27 (deep AI brain + $5000 resize, no real capital involved):**
  Systematically searched (initial lot x multiplier x distance x max legs)
  for a $5000-scale config where the full-load worst-case floating loss is
  small relative to the account (initial=0.02, 1.5x, $3 distance, 5 legs ->
  -$96, 1.92% of $5000) instead of guessing. Also deepened the self-tuner:
  it now tracks persistent (not just yesterday's) win/loss counts at every
  leg depth a basket has reached, and can step the max-legs cap itself up
  or down once a real sample exists — not just distance/multiplier/target.

  Stress-tested with `InpUseDailyLimit=false` again (the same test that
  wiped the account 100%+ three times before): this time it survived with
  only 12.35% drawdown and PF 0.94 — the self-tuner visibly widened DCA
  distance (3.0->3.8) and lowered the multiplier (1.5->1.30) in response to
  real trouble signals over the week, doing the daily-limit's job without
  ever needing a hard stop.

  User then asked to compare: hard-SL off + pyramid on (PF 0.69, DD 25.68%,
  worse), hard-SL off + pyramid off (PF 0.93, DD 21.78%, still worse DD
  than keeping hard-SL on) — confirming the hard-SL is worth keeping even
  though it doesn't cost profit factor, because it caps the worst-case
  single loss and overall drawdown by a lot.

  Also traced a real losing cycle from the trade history to answer "why
  didn't DCA just recover": a BUY basket added legs 1-3 as price fell $3 at
  a time, then a strong confirmed downtrend made the trend filter correctly
  refuse to add leg 4/5 (averaging into a strong opposing trend is exactly
  what the filter exists to prevent) — price then fell another $14.66
  beyond leg 3 with no more legs to lower the average, and the basket hit
  its hard-SL for a real, unavoidable loss. This is the concrete
  illustration of why "DCA always recovers, never loses" is not achievable:
  the same filter that protects against reckless averaging also removes
  the recovery mechanism at the exact moment the market is moving hardest
  against the position.

  Final change set (per explicit request): pyramiding removed entirely
  (never beat the no-pyramid baseline in any tested combination — best was
  PF 0.75, worst 0.62, versus 0.92-0.95 without it). `InpUseDailyLimit`
  now defaults to `false` permanently. In its place, added an intraday
  soft-brake to the AI brain: not a hard stop or force-close — once
  today's floating loss crosses 3%, it caps the lot multiplier down and
  widens the DCA distance for the rest of that calendar day only. Backtest
  with this final config: **PF 0.95, net -$253.02 (vs -$365.85 without the
  brake), max drawdown 11.68%, largest single loss only -$58.65** (vs
  -$150-190 in the no-hard-SL/pyramid tests) — the best result found so
  far, and the tuning log confirms the brake fired on 4 of 6 test days,
  exactly when that day's loss crossed the threshold.

  Still net-negative (PF 0.95, not >1.0) and still one week of data — this
  is real, repeatedly-verified progress, not a proven edge. "No losses,
  only profit" was asked for directly and is not something any DCA scheme
  can deliver with finite capital — this was stated plainly rather than
  faked. The honest next step, unchanged from before: validate this config
  against a different time period.

- **2026-07-27 (basket hard-SL turned off, real-tick 1-week retest):** Per
  explicit request, `InpBasketMaxLossUSD` set to `0.0` (off) — a basket's
  only remaining loss bound is now the wide catastrophic backstop SL per
  leg, not the tighter basket-level stop. Re-ran the same real-tick
  Strategy Tester setup ($5000, one week 2026-07-19 to 2026-07-26, 100%
  real ticks, 1280025 ticks / 6889 bars / 1905 trades):

  Result: **PF 1.02 (first config to cross 1.0), net +$147.10**, win rate
  71.13% — but equity drawdown jumped to **31.17% (-$2046.98)** and balance
  drawdown to 26.55%, versus 11.68% with the basket hard-SL on. Largest
  single losing trade widened to -$299.62 (was -$58.65), and there was an
  8-trade losing streak totaling -$1440.11 (28.8% of the $5000 account) in
  one stretch. This matches the exact tradeoff flagged before turning it
  off: crossing breakeven on this one week came from letting individual
  baskets ride out bigger adverse moves instead of cutting them at $150 —
  more of the "hope for a bounce" risk paying off this specific week, at
  the cost of a much rougher equity curve. Still one week of data, still
  not proof of a durable edge — same "validate on another period before
  trusting it" caveat as every prior result in this file.
