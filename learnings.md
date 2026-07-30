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

- **2026-07-27 (every remaining SL turned off, real-tick retest, same
  week):** Per explicit request, also disabled `InpUseCatastrophicSL`
  (the last-resort per-leg backstop) and zeroed `InpDailyMaxLossPercent`/
  `InpBasketSLCooldownMinutes` — combined with the earlier changes, no
  position this EA opens has any server-side stop anywhere. Re-ran the
  identical real-tick setup ($5000, 2026-07-19 to 07-26, 100% real ticks):

  Result: **PF dropped to 0.87, net -$562.03** — worse than both prior
  configs on this exact week, despite a higher raw win rate (74.29%).
  Balance drawdown 35.76%, equity drawdown 34.54% — both worse than the
  hard-SL-off-only run. Largest single loss widened further to -$582.63
  (was -$299.62), and there was a 10-trade losing streak totaling
  -$2470.62 in one stretch — **49.4% of the $5000 account in one
  sequence**. The catastrophic backstop SL was a wide, rarely-touched
  safety net, not a frequent trade-closer — removing it didn't unlock any
  extra profit potential on this week's data, it just removed the ceiling
  on how bad one bad stretch could get, and this week that ceiling would
  have mattered. Same caveat as always: one week of data, not proof of
  anything durable either way — but this specific change made the result
  worse, not better, on the data available so far.

  Traced the exact -$2470.62 streak in the raw deal log to explain it in
  plain terms: a SELL basket added legs 1-5 as gold rose from ~4023 to
  4039.77 (2026-07-24 05:54-07:04), hit max legs with nowhere left to add,
  and then price kept rising for another full day+ with no SL left to
  close it. At test end (2026-07-25 23:59:58) MT5 force-closed everything
  at the final price (4052.81) - that one stuck SELL basket alone lost
  -$2035.07, plus a separately-stuck BUY basket lost -$396.92, together
  accounting for nearly all of the week's net loss. This is the concrete
  answer to "why does loss happen if DCA is supposed to prevent it": DCA
  only helps if price eventually reverses before legs run out; once maxed
  out with no SL, a non-reverting move just sits open, unrealized, with
  nothing left to close it.

- **2026-07-27 (stuck-basket relief added to the AI brain, same week
  retested):** Built directly in response to the traced failure above.
  New rule: once a basket has been maxed out and stuck for
  `InpStuckBasketHours` (4h default) with no target hit, its required
  profit linearly shrinks toward `InpStuckBasketTargetFloor` ($0 /
  breakeven default) over the next `InpStuckBasketDecayHours` (8h) - so a
  stuck basket takes the first real exit instead of holding out for the
  full $2 target.

  Re-ran the identical real-tick week: **PF 0.86, net -$579.05** -
  essentially unchanged from before this feature existed (was PF 0.87,
  -$562.03), and the exact same -$2470.62 / 10-trade streak still
  happened, at the exact same prices, forced-closed at the exact same
  test-end moment. Traced why: by `InpStuckBasketHours` +
  `InpStuckBasketDecayHours` (4h + 8h = 12h after maxing out at 07-24
  07:04), the SELL basket's target had fully decayed to breakeven by
  ~07-24 19:04 - over 24 hours before the test ended. It never closed
  anyway, because **price never came back down to breakeven at all**
  during that entire stretch - it rose monotonically from 4039.77 to
  4052.81 with no meaningful pullback.

  This is an important, honest negative result: a rule-based "AI brain"
  can shrink *how much* bounce is needed to exit, but it cannot manufacture
  a bounce that never happens. When a move trends persistently in one
  direction with no reversion at all - not even back to entry - no
  amount of target-easing intelligence gets a maxed-out, SL-less basket
  out; only price cooperating (a real bounce) or a hard stop that accepts
  the loss can end it. The feature is still worth keeping (it will help on
  the much more common case of a partial, eventual pullback), but it did
  not save this specific traced example, and it's important that stays
  documented rather than glossed over.

- **2026-07-27 (catastrophic SL restored + max legs 5 -> 7, side-by-side
  retest, same week):** Traced the earlier +$147.10 "profit" run's deal
  log and found the catastrophic backstop SL had actually fired **52
  times** during that week — each time trimming one bad leg for a bounded
  loss (~$20-$100) instead of letting the whole basket ride unbounded to
  a forced test-end close. That backstop was doing real, load-bearing
  work, not sitting idle. Restored it (`InpUseCatastrophicSL=true`,
  `InpCatastrophicSLMultiple=2.0`) and, per request, also raised
  `InpMaxLegsPerBasket` from 5 to 7 (more room to average down before
  running out of legs, while the backstop still caps any single leg's
  worst case). Ran both back-to-back on the identical real-tick week for
  a direct comparison:

  | | 5 legs | 7 legs |
  |---|---|---|
  | Net Profit | +$147.10 | **+$2298.00** |
  | Profit Factor | 1.02 | **1.56** |
  | Win Rate | 71.13% | 72.53% |
  | Balance DD | 26.55% | **4.50%** |
  | Equity DD | 31.17% | **17.88%** |
  | Largest single loss | -$299.62 | **-$129.77** |
  | Worst losing streak | 8 trades / -$1440.11 | **6 trades / -$63.12** |

  A genuinely large improvement across every metric, not just profit -
  drawdown fell by more than 5x. Mechanism: more legs gives a basket more
  room to average its entry down (or up) before it runs out of DCA room
  and has to rely on the backstop, while the backstop SL keeps doing its
  job of bounding any individual leg's worst case. This is the best
  result found so far in this file. Same caveat as always: one week of
  data - validate against a different period before trusting this as a
  durable edge, not just a good week for a 7-leg config.

- **2026-07-27 (out-of-sample validation on other periods, per explicit
  request):** Correction first: real-tick history on this account actually
  extends back to at least 2026-07-12, not just 2026-07-19 as assumed
  earlier in this file - confirmed via a probe test ("100% real ticks"
  quality on 07-12 to 07-19). Ran two more tests with the current shipped
  config (7 legs, catastrophic SL on, everything else as-is):

  1. **2026-06-01 to 06-08** (Model=1, 1-min OHLC synthetic ticks, since
     real-tick history doesn't reach back that far): PF 1.80, net
     +$7531.79, balance DD 22.71% - but **equity DD 72.24%**, i.e. floating
     loss briefly reached nearly three-quarters of the account before
     recovering. A profitable week that also passed through a near-wipeout
     moment - the same "risk that happened to resolve favorably" pattern
     flagged repeatedly earlier in this file, just on a different config.
  2. **2026-07-12 to 07-19** (real ticks, genuinely non-overlapping with
     the 07-19..07-26 week already tested): PF 1.13, net +$936.75, balance
     DD 12.18%, equity DD 30.14%, win rate 74.12%.

  All three periods tested so far (07-19..07-26, 06-01..06-08,
  07-12..07-19) came back net profitable with PF > 1.0 - a genuinely
  encouraging, non-cherry-picked signal that this isn't purely a fit to
  one lucky week. But drawdown varies a lot between periods (4.50% to
  72.24% depending on the week) - the config has not yet shown it reliably
  keeps drawdown small, only that it (so far) always eventually recovers
  within the tested window. More periods, and ideally a real forward/demo
  test, are still the honest next step before trusting this as safe for
  real capital.

- **2026-07-30 ($100k capital test + market regime detection):** User asked
  to test running the same small lot (0.02) on a $100,000 account instead
  of $5,000 as a substitute for a hard SL - the reasoning being more capital
  buffer means DCA can go deeper before running out of room. Backtested
  (15 max legs, catastrophic SL on) on the same real-tick week: PF 1.58,
  +$3,975.42, drawdown down to 0.53%/1.47% - much safer, but only a 3.98%
  return on the $100k versus 45.96% on the $5k/7-leg config, since the same
  dollar-sized risk is now a smaller fraction of a much bigger account.
  Re-ran with catastrophic SL fully off too, 20 max legs: identical result,
  because this week's worst basket only reached leg 14 (worst-case ~$6,792,
  6.8% of $100k) - the SL was never actually needed this week, which is not
  proof it's safe, just that this week didn't test that edge.

  Then built real market-regime detection for the AI brain (per explicit
  request for "smarter AI" + "load years of data"): loads D1 history,
  ranks today's trend-strength and ATR as a percentile against that
  history, classifies TRENDING/RANGING/VOLATILE, and adjusts DCA distance/
  lot-multiplier-cap accordingly. Honest finding #1: this account's
  terminal only has ~480 days (1.3 years) of D1 history, not the requested
  5 years - a broker/data limitation, not fixable in code. Honest finding
  #2: backtesting it on the 07-19..07-26 week (classified RANGING every
  single day, tightening DCA distance to 0.85x throughout) made things
  worse, not better - PF 1.56 -> 1.37, drawdown roughly doubled. Shipped
  on by default anyway (per request) but explicitly flagged as unproven,
  not a validated improvement, in the README.

- **2026-07-30 (DCA cycling + dynamic profit target, per explicit request):**
  User asked for two changes together: (1) keep max legs at 7, but once a
  full cycle is used up without hitting target, start a new cycle instead
  of just waiting - lot sizing resets to `InpInitialLot` rather than
  compounding further; (2) the profit target should not be a flat number -
  it should scale up with how deep/risky the basket currently is. Built
  both: `InpMaxLegsPerBasket` is now a cycle length (real ceiling is the
  new `InpAbsoluteMaxLegsPerBasket`, default 50), and
  `GetBaseProfitTarget()` scales target by `(1 + completedCycles *
  InpCycleTargetGrowth)`.

  Backtested on the same real-tick week (07-19..07-26) against the proven
  flat 7-leg hard-cap config:

  | Config | Deposit | PF | Net | Balance DD | Equity DD |
  |---|---|---|---|---|---|
  | Flat hard-cap (previous best) | $5,000 | 1.56 | +$2,298.00 | 4.50% | 17.88% |
  | Cycling + dynamic target | $5,000 | 0.84 | -$1,068.77 | 50.30% | 54.48% |
  | Cycling + dynamic target | $20,000 | 1.12 | +$940.97 | 9.71% | 11.92% |

  Cycling underperforms the flat hard-cap at every capital level tested -
  worse PF, much worse drawdown, and even the $20k cycling run's *dollar*
  profit is smaller than the $5k hard-cap run's, despite 4x the capital
  (4.7% return vs 45.96%). The mechanism: hard-cap-and-wait freezes a
  basket's total exposure once maxed out and lets stuck-basket relief ease
  the exit over time; cycling instead keeps committing fresh capital in the
  same adverse direction every time a cycle completes, which compounds
  badly on exactly the kind of multi-day one-directional move this file has
  already documented (the traced SELL-basket example). More capital
  cushions this (the $20k run recovered to a small profit) but does not fix
  the underlying inefficiency.

  **User's explicit decision after seeing this data: keep cycling anyway.**
  Shipped as the default behavior. This is documented plainly so it is
  understood as a deliberate preference, not a validated improvement - the
  same honesty standard as every other result in this file.
