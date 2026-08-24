# XAUUSD Dual Basket DCA EA

This folder now holds **three independent EAs** - read this section first
to know which one you're looking at.

## 2026-08-24 (later still): v24 - dashboard label-spacing bug, found from
## the user's own live CXM screenshot

User posted a screenshot of v23 actually running live on the CXM demo
(252424) - first real look at this build outside a backtest. Everything
substantive checked out (correct version number, correct leg/cycle
counts, correct "License: not set (gate off...)" text, filters all
reading sane, trading-hours gate active), but three dashboard lines were
visibly running label text straight into the value with no space:
`Daily Targetoff`, `Daily Loss Limitoff`, `Trading Hoursopen (from
07:00)`. Root cause: `PadRight()` only *adds* spaces while the label is
shorter than the target column width (`lblW = 12`) - "Daily Loss Limit"
is 17 characters, "Trading Hours" is 13, "Daily Target" is exactly 12 -
all three either meet or exceed 12, so zero padding got added. Every
other label on the dashboard happened to be short enough that this never
showed. Fixed by raising `lblW` to 18 (covers the longest label with
room to spare) - cosmetic only, no logic touched. Recompiled clean as
v24. Not yet on the live CXM chart - that's the user's own deployment,
this only updates the repo's `.ex5`.

## 2026-08-24 (later still): v23 - deleted the now-permanently-dead
## `InpUnlimitedLegs`/`InpAbsoluteMaxLegsPerBasket` toggle pair

Explicit request: "যেগুলো setting কাজে লাগবে না সেগুলো delete করো, যাতে
professional লাগে" (delete whatever settings aren't needed, so the
Inputs dialog looks professional) - asked right after confirming
unlimited legs as a **final** decision (see the v22 entry above: shown
a real backtest reproducing the live blowup mechanism, chose to keep
unlimited legs anyway). With that choice now permanent, the
`InpUnlimitedLegs`/`InpAbsoluteMaxLegsPerBasket` pair was never going to
flip again - checked every other input for the same "declared but never
really live" pattern first (grepped each one's usage count across the
file) and this was the only genuine case; everything else still gates
real, actively-relevant behavior even where off by default (Daily Loss
Limit, News Filter overrides, etc. - "off by default" is not the same
as "not needed," so those stayed). `InpLicenseKey`/`LicenseOk()` stayed
too, deliberately - the user's own stated plan is to return to licensing
later ("licence পরে কাজ করবো"), so removing it now would just mean
rebuilding it soon; it's on hold, not dead.

Deleted both inputs, hardcoded the DCA-add condition to unconditional
(`if(adverse)`), updated the file header and `InpMaxLegsPerBasket`'s
inline comment to stop referring to a cap that no longer exists.
Recompiled clean (v23, 0 errors/0 warnings). Verified behaviorally
identical to v22 via a short smoke backtest (same window, same inputs
otherwise) - byte-identical trade sequence and stop-out point, as
expected since `InpUnlimitedLegs` was already permanently `true` before
this change; this was a pure Inputs-dialog cleanup, not a logic change.

## 2026-08-24 (later still): v22 - floating-loss-scaled profit target,
## and a real backtest that re-confirms the live blowup risk is structural

Explicit request: "$5000 floating loss -> minimum $1000 profit before
releasing" (a 20% ratio), because v21's per-leg-growth-only target could
let a genuinely deep basket release for a target tiny relative to how
much it just survived. Added `InpTargetPercentOfFloatingLoss` (default
20.0) and rewrote `GetProfitTarget()` to
`MAX(per-leg baseline, |floatingPL| * pct/100)` - matches the user's
example exactly, only takes over once a basket is genuinely underwater.
Compiled clean (0 errors, 0 warnings) as v22.

**Verification surfaced two real process bugs before the result could be
trusted, and then a result worth taking seriously on its own:**
1. The terminal used for local Tester runs had a **stale `.ex5` from
   2026-08-16** sitting in its own `MQL5\Experts\` folder - predating the
   entire v21 direction-change. `metaeditor64.exe /compile` writes the
   output next to the source file it's given, not into every terminal's
   own Experts folder - a real gap in the compile workflow, now fixed by
   always copying the fresh `.ex5`/`.mq5` into the target terminal's
   `MQL5\Experts\` before testing, and by checking the Tester report's
   own echoed `Inputs:` section actually lists every current input group
   before trusting any number from it.
2. Could not log into the CXM demo (252424, `XAUUSDc`) used for every
   prior apples-to-apples backtest in this project - its password isn't
   cached locally. Substituted the only reachable account (Exness demo,
   plain `XAUUSD` symbol) rather than skip verification - but that
   source's own report header self-reports only **12% real ticks**, a
   real data-quality caveat on the number below.

**The result, correct binary, caveated data: $20,000 -> final balance
-$22,379.76, in under 8 hours** (2026.07.01 07:00-14:35 server time, the
very first day the 7am gate allowed trading). XAUUSD rallied
~$3,972 -> $4,111 (~3.5%) in one direction; the SELL basket kept adding
legs into the rise the entire time (unlimited legs, no SL, per the v21
design) until margin ran out - 983 trades, profit factor 0.30, margin
level 0.03% at stop-out. Confirmed (by re-running with
`InpTargetPercentOfFloatingLoss=0`) this is not caused by the new
formula - it's the same structural risk that produced the real
2026-08-24 CXM blowup, reproduced here in a controlled backtest on day
one of the window.

Reported honestly to the user, with the data-source/binary caveats made
explicit rather than presented as a clean apples-to-apples result.
**User's explicit decision after seeing this: keep unlimited legs as-is,
no basket-level cap added - the risk is understood and accepted.** Full
writeup in `ml/learnings.md`'s 2026-08-24 (v22) entry.

## 2026-08-24 correction: v21's -$275.58 result was wrong - a stale
## `.set`-file value silently re-enabled Daily Loss Limit during the test

Asked to investigate why v21 (see the entry below) still lost money
despite "never book a loss," parsed the Tester report properly (grouped
deals by close time+price+side) instead of re-guessing, and found the
real cause: a 47-leg basket closed at **-$1,013.63** - not via SL, not
via TP (which can't produce a basket-wide loss by construction) - via
`ForceCloseOnDailyLossLimit()`. `InpUseDailyLossLimit` was `false` in
the compiled defaults and never set in `[TesterInputs]`, but a **stale
cached `.set` file** from an earlier v19 test session (where it was
deliberately `true`) silently overrode the default - this project's own
documented `.set`-file caching gotcha, which bit this session anyway.

Re-ran with `InpUseDailyLossLimit=false` explicitly passed this time,
same window, same $20,000 deposit: **net +$699.49, profit factor 1.81,
max equity drawdown 7.39%, 2,938 trades.** The basket that previously
got force-closed at a big loss was allowed to keep averaging and
eventually recovered - the "never book a loss, unlimited legs" theory
held up in this specific backtest window once actually tested correctly.
Drawdown is meaningfully higher than the (also wrong) earlier number,
which is the real, honest cost of letting a basket ride instead of
cutting it - one window's result, not a guarantee it always recovers.
**Lesson written down for future test runs: always pass every input
that changes behavior explicitly in `[TesterInputs]`, never assume the
compiled default silently applies in the Tester.** Full writeup in
`ml/learnings.md`.

## 2026-08-24: v20 blew a demo account to $0.62 (real, understood, not a
## new bug) -> v21: unlimited legs, never book a loss, license removed

Three days after v20 went live unattended on the CXM demo, it dropped
from $10,175 to **$0.62**. Root-caused from the account's own exported
history (not guessed): gold moved ~$37 (~0.8%) in ~10 minutes, and a BUY
basket that had already cycled deep (0.32/0.64-lot legs) kept adding legs
straight through the crash - one single 0.64-lot leg alone lost
**-$2,354.80**. `InpUseDailyLossLimit` (built exactly for this) was off.
This is the real, live version of exactly what this project's own
research named: "months of small wins, one trend erases it all" - not a
new failure mode, the first live demonstration of the standing "no
stop-loss ever" decision's actual cost.

The user's response was not to add the safety net, but to go further in
the opposite direction - implemented as explicitly asked, after stating
the one concrete mechanical consequence once (a broker margin call
becomes the only remaining backstop with no self-imposed leg cap):
- **`InpUseTradingHours`** (default true) - new entries only from
  **7am** server time daily, existing baskets still managed anytime.
- **`InpUnlimitedLegs`** (default true) - no cap on total legs; a basket
  can DCA indefinitely. The lot-size-reset-every-`InpMaxLegsPerBasket`-legs
  cycling stays, so "unlimited legs" doesn't also mean "unlimited
  single-leg lot size" (which would hit the broker's own max-lot limit
  almost immediately).
- **`InpUseMultiTFTrend`** default flipped to **true** - H1+H4+D1 must
  all agree now, not just H1.
- **License check removed** from the entry gate (function/key-list still
  in the file - one line to restore) - "get it working first, license
  later."
- **`InpBasketProfitTargetUSD`** lowered to **$1.00** (from $2.00).

Confirmed via the Tester report: **zero `sl`-tagged closes anywhere** -
the no-loss-booking design works exactly as specified, every close is a
basket-level TP hit. **Real Tester run** (Model=4, every tick, XAUUSDc/
CXM, the same 2026.07.01-08.10 stress window, $20,000 deposit): **net
-$275.58, profit factor 0.80, max equity drawdown 5.34%, 3,125 trades.**
Still a net loss overall even with zero SL-closes, because a basket's
shared TP can let a late-joined leg realize its own loss even while the
basket as a whole reaches target - reported as found. Full writeup,
including the 10-leg target-growth worked example ($1.64 at leg 10, still
climbing since legs no longer cap), in `ml/learnings.md`'s 2026-08-24
entry. Compiled clean (0 errors, 0 warnings) as v21, not yet deployed
anywhere - the account that blew up was demo, no real money lost.

## 2026-08-21 (later still): smooth per-leg target growth, v20 - backtest
## says worse, kept for live evaluation per explicit user decision

Changed `GetProfitTarget()` so the basket profit target ramps a little
with *every* DCA leg instead of jumping once per full 7-leg cycle (the
v19 behavior). Same overall growth rate, spread evenly instead of dumped
in one jump - but a real backtest over the same window used to verify
v19 came back clearly worse, not better: net profit $603.59 -> $222.12,
profit factor 3.04 -> 1.25, max equity drawdown 2.46% -> 5.35%. Reason
worked out, not just observed: raising the target for mid-cycle legs too
means a basket takes longer/more legs to actually close, keeping more
capital deployed during the adverse move for longer.

Recommended reverting to v19's step function given these numbers - the
user's explicit choice instead was to keep v20 as compiled and evaluate
it live/demo before deciding, rather than go by the backtest alone. Full
numbers and the worked-out explanation in `ml/learnings.md`'s relevant
2026-08-21 entry. Compiled clean (0 errors, 0 warnings), not yet
deployed anywhere as of this commit.

## 2026-08-21 (later same day): dual-basket EA gets a daily loss limit, v19

Research into what separates surviving martingale/grid EAs from ones that
blow up named one feature above the rest: a hard portfolio-level loss stop
that force-closes everything once cumulative drawdown hits a threshold.
This EA had a daily *profit* target but nothing on the loss side - added
`InpUseDailyLossLimit` (default off) + `InpDailyLossLimitPercent` (5.0):
checks live equity (not just realized balance, since floating loss is the
actual danger), halts new entries, and force-closes both baskets.

Tested against the exact July 2026 window that used to wipe real accounts
(documented lower in this file/`ml/learnings.md`): with current, already-
improved defaults, max equity drawdown over that window is now only
**2.46%** (was enough to wipe a $5-10k account back when this was
documented). Also tested softening `InpLotMultiplier` from 2.0 to 1.3 as
an additional lever - counter-intuitively, this made things *worse*
(lower profit, higher drawdown: 3.72% vs 2.46%), isolated via a control
test to confirm the loss limit itself had zero effect in this window (it
never triggered - baseline-identical numbers) and the multiplier change
was the entire cause. Recommendation: keep the multiplier at 2.0, turn
the new loss limit on as a no-cost safety net for a genuine tail event.
Full numbers in `ml/learnings.md`'s second 2026-08-21 entry.

## 2026-08-21: third EA - `FarhanFX Order Flow Strategy.mq5` (v1)

A cumulative-volume-delta (CVD) divergence EA, built after the Trend
Strategy EA's first backtest (below) came back modest and the user asked
to try order flow instead. Important honest caveat up front: XAUUSD is an
OTC CFD with no consolidated exchange order book, so **real institutional
order flow (Level 2/footprint data, which would come from CME GC futures)
is not available through this MT5/broker setup** - confirmed via research
and explicitly agreed with the user before building. What this EA actually
computes is a **tick-direction volume-delta proxy**: every real tick in a
bar is classified as buy- or sell-pressure (by the broker's own trade-side
flag when present, otherwise by price direction vs. the previous tick),
summed into that bar's delta, and accumulated into a running CVD that
resets each trading day.

**Signal**: bearish divergence (price makes a new confirmed pivot high,
but CVD at that pivot is lower than at the previous pivot - price up
without real buying pressure behind it) and the bullish mirror. Real
broker-side SL (`1.5x ATR`) and a single fixed-R:R take-profit
(`InpRewardRiskRatio`, default 2.0) - deliberately the simpler exit style
vs. the Trend EA's 6-level scaled ladder, so the two EAs are two genuinely
different, comparable data points. Same dashboard/license/broker-preset/
branding patterns and position-sizing convention as the Trend EA below.

**Verified via a real Strategy Tester run** (Model=4, every tick/real
ticks - required here specifically, since CVD math depends on real
tick-level data; Model=1 would not exercise the real logic at all),
XAUUSDc/CXM, the identical 2026.06.01-08.18 window used for the Trend EA
so the two are directly comparable:

| | Trend Strategy (EMA ribbon) | Order Flow (CVD divergence) |
|---|---|---|
| Trades | 121 | **7** |
| Profit Factor | 1.66 | 1.17 |
| Net profit | +$55.62 | +$5.64 |
| Max drawdown | $14.87 (0.15%) | $34.15 (0.34%) |

Honestly: the order-flow signal is real (SL/TP fire correctly, the CVD
math checked out bar-by-bar against real price action in a sanity pass)
but **fires far too rarely to draw any real conclusion from 7 trades**,
and what did fire performed worse per-trade than the Trend EA, not
better. All 7 trades were SELL entries in this window - no BUY divergence
fired at all, likely just a reflection of this specific window's mostly-
declining price action rather than an asymmetry bug, but not independently
confirmed. See `ml/learnings.md`'s 2026-08-21 entries for the full
writeup. Not yet deployed to any live/demo chart.

## 2026-08-21: second EA - `FarhanFX MTF Trend Strategy.mq5` (v1)

A deliberate architectural break from the dual-basket EA below: single
position per direction, **real broker-side stop-loss on every entry**, no
martingale, no DCA legs. Built after market research into how consistently
profitable traders actually operate (sub-1% risk discipline, 2:1-3:1 R:R,
hard predefined stops - the opposite of the dual-basket EA's no-SL design)
found that design pattern is exactly what causes accounts to blow up - and
the same week, that EA produced two real live bugs that would have been
far less dangerous with a real SL as a backstop.

Ported from an existing, already-designed TradingView strategy -
`E:\Farhan Fx Algo\FarhanFX_MTF_Trend_Strategy.pine` (+ companion
`FarhanFX_MTF_Trend_Indicator.pine`) - rather than designed from scratch:
a 6-EMA Fibonacci ribbon trend system (periods shift by a timeframe preset,
default 30m: 8/13/21/34/55/89) with candlestick + support/resistance + RSI
confluence filters gating entries, entry only on a fresh alignment *flip*
(not "aligned" as a continuous state), a real SL at `1.5x ATR(14)`, and a
6-level ATR-stepped scaled take-profit (partial closes at each level,
calibrated so each slice equals 1/6 of the original entry size). Exits
immediately if the ribbon loses full alignment while a position is open,
regardless of TP progress ("trend exit").

**Position sizing is notional (`InpPositionPercentOfEquity`, default 10%
of equity), not risk-based** - a deliberate exception to the research
findings above, matching the Pine script's own `percent_of_equity` mode by
explicit user request, so results stay comparable to whatever the Pine
version has already shown on TradingView. Real $ risked per trade still
varies with SL distance, exactly as it does in the Pine backtest.

Dashboard/license/broker-preset/branding infrastructure (the `DbLabel`/
`DbDivider`/`CreateButton` helpers, the embedded license-key list + non-
blocking gate pattern, `ENUM_BROKER_PRESET`/`EffectiveMaxSpreadPoints()`,
the gold-branded dashboard + chart watermark) is reused in pattern from
`Scalping Ai Pro By Farhan FX.mq5` below, so it looks and operates
consistently with what the user already knows - same license keys, same
verified broker constants, same "license check must never block
`OnInit()`" lesson applied from day one instead of re-learned the hard way.

**Verified via a real Strategy Tester run** (Model=4, every tick/real
ticks, XAUUSDc/CXM, 2026.06.01-08.18, $10,000 deposit): real SL fired
correctly (`sl 4488.565` etc. in the deals table), the scaled TP ladder
fired correctly (multiple partial closes at distinct price levels on the
same position, e.g. one SELL position partial-closed 0.04 lots at TP1 then
had its remaining 0.20 lots stopped out later), 121 trades, profit factor
1.66, net +$55.62, max drawdown **$14.87 (0.15%)** - dramatically smaller
than anything the dual-basket EA has ever shown, as expected from an EA
with an actual stop-loss. Explicitly a backtest-only result, not a live
track record - see `ml/learnings.md`'s 2026-08-21 entry for the full
writeup, sources for the research, and honest caveats.

Not yet deployed to any live/demo chart.

---

## `Scalping Ai Pro By Farhan FX.mq5` - dual-basket DCA/martingale EA

File (final, permanent name per explicit request): **`Scalping Ai Pro By
Farhan FX.mq5`** / `.ex5`. Note this is the same name as the separate,
unrelated Python ML project at `E:\Scalping AI Pro By Farhan Fx` — the user
was told this explicitly and confirmed the name anyway, so it's
intentional, not a mix-up. This repo/folder (`XAUUSD Dual Basket DCA EA`)
and everything in it is the native MQL5 grid/DCA EA documented below; it
has no code relationship to that other project.

Every position this EA opens is tagged with magic number `InpMagicNumber`
(default `20270115`) and a trade comment like `FarhanFx-buy-leg1` /
`FarhanFx-sell-leg3` (visible in MT5's Trade/History "Comment" column),
distinct per leg number and direction so it's easy to tell legs apart at
a glance.

Native MQL5 Expert Advisor for XAUUSD (M1). Runs a BUY basket and a SELL
basket simultaneously (requires a **hedging-mode** MT5 account). Each basket
targets a floating-profit dollar amount, closes, and immediately reopens. On
an adverse price move past the last leg, adds a martingale DCA leg — capped,
filtered, and safety-netted (see below) after this user's prior similar EA
(`E:\Straddle Ai Buy Sell Pending EA\StraddleAI_EA.mq5`) blew up a demo
account with uniform lot sizing, no leg cap, and no floating-loss circuit
breaker.

## 2026-08-12: simplified back to core logic only (read this first)

Earlier versions of this EA (documented further down, kept for historical
record) grew a daily self-tuner, a historical market-regime detector, and a
trained ML (ONNX) stuck-basket-risk filter on top of the core logic below.
All three were live-tested on a VPS demo and, while individually working as
designed, made the EA's behavior harder to predict from the input list alone
— and the ML filter specifically sometimes deliberately paused martingale on
a risk read, which conflicted with the user's actual, explicit requirement:
**always martingale through an against-trend position until profit, no
exceptions, no pauses**. Per direct user instruction, all three were removed
from the code (not just disabled) as of build `2026.08.12.1`, so the current
input list matches exactly what the EA does — no hidden auto-adjusting
behavior anywhere. The self-tuner/regime-detection/ML sections further down
in this README describe the removed history for context; they are no longer
part of the running EA. Full removal rationale in `ml/learnings.md`
(2026-08-12 entries).

## 2026-08-18: two real bugs found live on demo, fixed same day, build v18 (read this first)

v17 went live on two demo charts (CXM 252424, Exness 416045126) and the
user caught both of these directly from the dashboard/trade blotter within
hours - neither showed up in a backtest:

1. **TP set $100 away from entry instead of ~$1-2.** `BasketTargetPrice()`
   used `SYMBOL_TRADE_CONTRACT_SIZE` to convert the $ target into a price
   distance - on this cent-account symbol that metadata field disagreed
   with how the broker's own `POSITION_PROFIT` actually computes profit.
   Fixed by switching to `SYMBOL_TRADE_TICK_VALUE / SYMBOL_TRADE_TICK_SIZE`,
   which matches `POSITION_PROFIT` by construction, not by assumption.
2. **A basket cascaded through a full 7-leg cycle in ~9 seconds** (CXM),
   entries spanning only ~35 cents total vs. the intended $1.2/leg -
   confirmed not a misconfiguration. Root cause: `ScanBasket()`'s
   "most recent leg" tie-break used `POSITION_TIME` (1-second resolution);
   legs opening faster than 1/second could tie and pick the wrong
   reference price. Fixed with `POSITION_TIME_MSC` (millisecond
   precision) plus a new independent safety net, `InpMinSecondsBetweenLegs`
   (default 5) - no new leg within N seconds of the previous one, full
   stop, regardless of what the distance check computes.

Verified via a real Tester run (Model=4, every tick, real ticks): no
consecutive same-side leg-open pair under 5 seconds apart in a 9-day run
(1 expected exception - a fresh bootstrap, which has no cooldown gate).
Full writeup in `ml/learnings.md`'s 2026-08-18 entry, including the
meta-lesson: both bugs were only found by running live on demo and
watching it, not from a backtest - now a required step for any pricing-
logic change, not optional on top of a Tester pass.

## 2026-08-16 (later same day): server-side TP, build v17

Real bug report after running live for a while: baskets logged "TARGET
HIT" while the real account balance still trended down, worse during
momentum. Root cause: `CloseBasket()` closed a basket's legs one-by-one
via separate market orders - during a fast move, later legs in that loop
could fill at a meaningfully worse price than what was used to declare
"target hit" moments earlier (real, momentum-correlated slippage), on
top of commission never being visible to the EA at all (MQL5 has no
live-commission field on an open position).

Fix: **`InpUseServerSideTP` (default true)** - every leg in a basket now
gets a real broker-side TP set to the exact price where the basket's
combined floating P/L reaches its target, so the broker's own server
closes every leg simultaneously the instant price reaches it, instead of
the EA detecting it a tick late and closing legs one-by-one. New "TP
Price" line per basket on the dashboard. The existing tick-based close
stays in place as a backup (in case a TP fails to set on some leg).

Verified via a real Strategy Tester run (Model=4, every tick, real
ticks): a 7-leg basket's legs all closed at the identical timestamp and
price with a `tp` comment - confirmed working as designed. Full details,
including an unrelated test-environment scare along the way (fully
documented, resolved, not a code bug) in `ml/learnings.md`.

## 2026-08-16 (earlier same day): chart visuals / branding, build v16

Added on top of v15, purely cosmetic (no trading-logic function reads any
of this, so it cannot change entries/exits/lot sizing):
- DCA leg markers on the chart (`InpShowLegMarkers`, default true) - a
  small label at each leg's open time/price, deleted the instant that
  leg closes, so it never accumulates.
- Basket-closed markers (`InpShowCloseMarkers`, default true) - a
  "BUY closed +$2.10" label when a basket hits target, capped at the
  most recent 20.
- Dashboard branding - gold accent strip + gold-tinted border, the real
  Farhan FX logo mark embedded as a small icon (`resources/FarhanFX_Icon.bmp`,
  compiled into the .ex5 via `#resource` - no separate file needed on a
  client machine), and the title on its own two lines ("SCALPING AI PRO"
  white, "FARHAN FX" gold - an initial same-line layout overlapped on
  real hardware, fixed by stacking instead of guessing pixel widths).
- `InpSetWhiteChartTheme` default flipped to `false` (dark) to match the
  logo's black background.
- A faded Farhan FX watermark (`resources/FarhanFX_Watermark.bmp`,
  420x310) centered on the main chart itself, behind the candles
  (`InpShowChartWatermark`, default true) - separate from the small
  dashboard-corner icon above.

Compiled clean (0 errors, 0 warnings). Full details in `ml/learnings.md`'s
2026-08-16 entries, including three other ideas offered but not picked
this round (Telegram alerts, equity-protection circuit breaker, license
tiers/expiry).

## 2026-08-16: license system rebuilt, build v15 (read this first, supersedes v14 note below)

The offline embedded-key-list idea from 08-13 (see the 08-14 note below)
was right, but the *first* implementation gated it inside `OnInit()`
with `return(INIT_FAILED)` on a missing/wrong key. On the real account
(263521212) that produced exactly the "dashboard stays black" symptom
the user reported - `OnInit()` failing means `CreateDashboard()` never
runs, so there's no panel at all, which looks like a freeze/lag rather
than a license refusal. That version was fully reverted to v9 at the
time (`git checkout 4b11201`).

v15 rebuilds the same offline embedded-key idea, but as a **non-blocking
runtime gate** instead of an `OnInit()` refusal:
- `g_authorizedLicenseKeys[]` - hardcoded in the .mq5/.ex5, no network
  call at all (same 20 keys from 08-13's admin panel batch). Give each
  client their own key individually when they join under your ID;
  editing this array + recompiling is how a key is added or revoked.
- `LicenseOk()` is checked inside `ManageBasketEntries()`, in the exact
  same spot/pattern as the existing `IsNewsBlackout()`/`DailyTargetHit()`
  checks - an invalid key just skips new bootstrap/DCA entries for that
  tick. `OnInit()` and the dashboard always run regardless.
- Dashboard shows a `License: OK` / `License: INVALID (no new trades)`
  line at all times, so the state is never silent or ambiguous.

Full root-cause writeup is in `ml/learnings.md`'s 2026-08-16 entry.
Not yet redeployed to the real-account terminal (263521212) or the VPS.

## 2026-08-14: current final state, build v14 (superseded by the v15 note above for licensing; still accurate for everything else)

The 2026-08-12 simplification above is still accurate for the *shape* of
the logic (no self-tuner/regime-detector/ML, no hidden auto-adjusting
behavior), but a full day of further work on 2026-08-13/14 added real
features on top and changed several defaults. Version numbering also
changed from date-based build strings to simple `v1`, `v2`, ... shown on
the dashboard - **check the dashboard's version line against the latest
entry in `ml/learnings.md` before trusting a running chart is current.**

What v14 actually has that the EA didn't in the 08-12 baseline:
- **News Filter** (`=== News Filter ===`) - MT5's built-in economic
  calendar, live/demo only (confirmed non-functional inside the Strategy
  Tester - a platform limitation, not a bug). Plus a manual date/time
  blackout window, independent of the calendar, usable in the Tester.
- **Daily Profit Target** (`=== Daily Profit Target ===`) - stops new
  trades for the rest of the day once today's *realized* profit hits a
  threshold; resumes automatically at the next day rollover. Off by
  default.
- **Multi-timeframe trend confirmation** (`InpUseMultiTFTrend`) - optional
  stricter trend filter requiring H1+H4+D1 to agree, instead of just H1.
  Off by default in the current client-distribution defaults.
- **Broker Preset + Account Type** (`InpBrokerPreset` / `InpAccountType`) -
  auto-sets `Max Spread (points)` correctly per broker, because the same
  real $ spread shows up as a very different raw points number depending
  on the broker's symbol digit/point convention (discovered the hard way:
  Exness's cent account needed 5000, not the 300 that's fine on its
  standard account). Verified with real accounts: Exness (300/5000
  standard/cent), CXM Direct (300 both), Vantage (300 both, cent
  confirmed - standard assumed by the same pattern, not independently
  tested). `Custom` uses `Max Spread (points)` directly for anything not
  in the list.
- Current client-distribution defaults: `InpMaxLegsPerBasket=7`,
  `InpInitialLot=0.01`, `InpExpectedLogin=0` (skip check - each
  deployment sets its own account number), `InpUseMultiTFTrend=false`,
  `InpDcaDistancePrice=1.2` (tightened from the original $3.00/$2.00
  after a real backtest sweep found it reduced losses across the board -
  see `ml/learnings.md`).
- **A license-key system was built, tested, then explicitly reverted** at
  the user's request (no online server existed yet that a VPS could
  reach, and the first offline-key version caused the dashboard-black
  bug diagnosed and fixed in the v15 note above) - as of v14 the `.ex5`
  has no license gate. As of **v15**, the offline embedded-key-list
  check is back, rebuilt as a non-blocking runtime gate this time - see
  the v15 note at the top of this file and `ml/learnings.md`'s
  2026-08-16 entry.
- An **MT4 port** (`Scalping Ai Pro By Farhan FX.mq4`) exists in this repo
  as source only - written, matches this EA's logic, but **never
  compiled or tested** (no MT4 terminal available in this environment).
  Treat it as unverified until someone with a real MT4 terminal compiles
  and smoke-tests it.

Full day-by-day history of every change, every real bug found, and every
backtest result behind these defaults is in `ml/learnings.md` - that file
is the authoritative record, this README is a summary.

## Core logic

- Bootstrap: if a basket is empty, open one `InpInitialLot` leg.
- Profit target: once a basket's summed floating P/L reaches its current
  target, close every leg in that basket and reopen fresh. The target is
  **not flat** — see "DCA cycling" below.
- DCA: if price moves `InpDcaDistancePrice` adverse past the basket's last
  leg, add another leg sized at `InpLotMultiplier`x the initial lot (per
  position-in-cycle, not compounded off the previous leg, to avoid rounding
  drift), up to `InpAbsoluteMaxLegsPerBasket` legs total (hard safety
  ceiling, default 50).
- DCA filters: skips the add if `IsAtrSpiking()` (a volatility-spike "news
  proxy" — real economic-calendar integration wasn't wanted) or if
  `InpUseTrendFilter` finds a strong higher-timeframe trend against the
  basket's direction.

### DCA cycling (added 2026-07-30, per explicit request)

`InpMaxLegsPerBasket` is a **cycle length**, not a hard stop. Once a basket
uses up a full cycle (e.g. 7 legs) without hitting target, it doesn't just
sit and wait — the next leg resets lot sizing back to `InpInitialLot` and a
new cycle begins (leg 8 is sized like leg 1, leg 9 like leg 2, etc.),
continuing until `InpAbsoluteMaxLegsPerBasket` (the real ceiling). This
avoids the earlier problem of lot size compounding to an unaffordable size
by leg 15-20 (see learnings.md for the exact math), at the cost of
committing more capital into a move that has already proven to go against
the basket for a full cycle.

To compensate, the profit target itself scales up with depth instead of
staying flat: `target = InpBasketProfitTargetUSD * (1 + completedCycles *
InpCycleTargetGrowth)` — a basket that has survived more cycles carries
more risk, so it demands proportionally more profit before it's worth
closing. `GetBaseProfitTarget()` computes this; stuck-basket relief (below)
still eases down from whatever this scaled target currently is, not from
the flat base.

**Backtested and found to underperform the simple hard-cap approach** (see
learnings.md 2026-07-30) — tested at $5,000 (net -$1,068.77, PF 0.84) and
$20,000 (net +$940.97, PF 1.12) on the same week where the flat 7-leg
hard-cap scored +$2,298, PF 1.56. **Kept anyway per explicit user
preference** after seeing these results, not because backtesting supports
it — flagged plainly so this isn't mistaken for a validated improvement.

## Safety (beyond the original spec — added deliberately)

- `InpBasketMaxLossUSD` (default `0.0`, **OFF per explicit request**): hard
  stop-loss per basket, independent of the leg cap — a maxed-out basket that
  keeps losing otherwise has no exit. Currently disabled.
- `InpBasketSLCooldownMinutes` (default `0`, off): after a hard-SL close
  (not a profit-target close), the basket would wait before reopening
  rather than instantly re-entering into the move that just stopped it out
  — moot while the hard-SL above is off.
- `InpUseCatastrophicSL` (default `true`, **restored 2026-07-27**): a wide
  backstop SL attached to every leg at order time. Briefly turned off per
  request, then restored after tracing the trade log of the run where it
  was on: it fired 52 times over one real-tick test week, each time
  trimming a single bad leg for a bounded loss (~$20-$100) instead of
  letting a whole basket ride unbounded — this was the main reason that
  particular config was net profitable. See learnings.md for the full
  trace and the side-by-side numbers.
- `InpExpectedLogin` (default `416045126`): refuses to run (`INIT_FAILED`) if
  the connected account doesn't match — same wrong-account guard used in this
  user's other bots after a prior incident.
- Hedging-mode check in `OnInit()` — this EA's whole design breaks silently
  on a netting account (the two baskets would net against each other).
- Daily circuit breaker (`InpUseDailyLimit`, **off by default per explicit
  user request** — see below), force-closes both baskets when enabled
  (`InpDailyLimitForceCloses = true`) rather than just halting new entries.
- Intraday soft-brake (part of the AI brain, see below) — the substitute
  mechanism now that the daily circuit breaker defaults off.

**Current state (2026-07-31, FINAL per explicit request):**
`InpUseCatastrophicSL=false` and `InpLotMultiplier=2.0` (up from 1.5).
This reverses the 2026-07-27 restoration above — **every stop-loss in this
EA is now off, and each DCA leg is sized twice as large as the previous
one instead of 1.5x.** This was backtested immediately before shipping,
twice, specifically to check this exact combination:

- $5,000 deposit, same real-tick week (07-19..07-26): **net -$5,351.74,
  PF 0.51, balance/equity drawdown 104.74%/106.49%. MT5's own broker-side
  stop-out fired 64% of the way through the week; final balance went
  negative (-$351.74).** This is not a theoretical worst case — it is what
  actually happened on real historical price data with this exact config.
- $10,000 deposit, identical settings, same week: net -$4,712.71, PF 0.61,
  balance/equity drawdown 59.36%/79.51%. No broker stop-out this time, but
  nearly 80% of the account was underwater at the worst point, and this is
  after *doubling* the account size — the underlying imbalance (small,
  capped wins vs. now-unbounded, doubling-lot-size losses) is not
  capital-dependent.

**Shipped as the final configuration anyway, per explicit user decision
made after reviewing both results above.** This is documented in full
here and in learnings.md (2026-07-31 entries) so it is unambiguous that
this was a deliberate choice made with the real numbers in hand, not an
oversight or a claim that it is safe.

**On `InpUseDailyLimit=false`**: stress-tested repeatedly. With earlier,
smaller-account configs it wiped the account completely every single time
(100%+ drawdown, negative equity) — 3 runs in a row. It is a real,
meaningful safety layer being deliberately given up per explicit request,
not a redundant one. The intraday soft-brake below is a genuine mitigation,
not an equivalent guarantee.

## Trained ML models (`ml/` subfolder, 2026-08-05)

Beyond the rule-based "AI brain" below, this project has a genuine, Python-
trained ML research effort in `ml/` (full story in `ml/README.md` and
`ml/learnings.md`). Two models were researched:

- **Trend-continuation**: NOT shipped — no honest edge found (matches the
  sibling `Scalping AI Pro By Farhan Fx` project's own conclusion on raw
  XAUUSD direction prediction).
- **Stuck-basket-risk**: shipped, gated behind `InpUseMLStuckRiskFilter`
  (default **false**). Predicts P(this DCA-add leads to a multi-cycle,
  hours-stuck basket) via an ONNX model (`OnnxCreate`/`OnnxRun`), holdout
  AUC 0.81 on genuinely held-out historical episodes. Additive/veto-only —
  can skip or damp a DCA-add, never overrides the rule-based filters to be
  *less* conservative. **Runtime-verified in the real MT5 Strategy Tester
  (2026-08-06)** — two real bugs found and fixed (model needs
  `ONNX_COMMON_FOLDER`; both `OnnxSetOutputShape()` calls were missing).
  Backtested ML ON vs OFF, same $10,000/real-tick week: net loss roughly
  halved, PF 0.61->0.71, drawdown cut 18-31 points, shorter losing
  streaks — a genuine, verified improvement (still net-negative overall,
  since ML doesn't touch the no-SL/2.0x-multiplier configuration itself).
  Full story in `ml/learnings.md`.

## Self-tuning "AI brain"

Native MQL5 has no ML libraries, so this is a **rule-based, not trained**
brain (confirmed with the user as the realistic scope). Two layers:

1. **Daily nudges**: once per new day, reviews yesterday's closed trades
   (grouped into basket-close "cycles") and nudges `DcaDistance`/
   `LotMultiplier`/`ProfitTarget` within bounded ranges — conservative by
   design: only widens distance / lowers multiplier on real trouble signals,
   never tightens risk just because a good day happened.
2. **Deep, persistent leg-depth history**: tracks real (not just yesterday's)
   win/loss counts at every leg depth a basket has ever reached
   (`GetLegStat`/`IncrementLegStat`). Once a leg depth has enough samples,
   a poor win rate there steps the active max-legs cap down; a strong one
   lets it step back up (bounded by `InpMaxLegsPerBasket`).
3. **Market regime detection** (`InpUseRegimeDetection`, added 2026-07-30):
   loads daily history (`InpRegimeHistoryYears`, default 5 - but capped by
   however much D1 history the terminal actually has; on this account/broker
   that's only ~480 days / 1.3 years, not the full 5) and ranks today's
   trend-strength and volatility (ATR) as a percentile against that whole
   history. Above `InpRegimeTrendPercentile` -> TRENDING (widens DCA
   distance); above `InpRegimeVolPercentile` -> VOLATILE (caps lot growth);
   otherwise RANGING (tightens DCA distance, this EA's easiest case).
   **First backtest was a negative result**: on the 07-19..07-26 week (which
   classified as RANGING every day, tightening distance to 0.85x), PF fell
   from 1.56 to 1.37 and drawdown roughly doubled versus the same config
   without regime detection - see learnings.md. Left on by default with
   this shipped, but it is not yet a proven improvement.
4. **Intraday soft-brake** (added when the daily circuit breaker was turned
   off by default): NOT a hard stop or force-close. Once today's floating
   loss crosses `InpIntradayBrakeLossPercent` (default 3%), it caps the lot
   multiplier down (`InpIntradayBrakeMultiplierCap`) and widens the DCA
   distance (`InpIntradayBrakeDistanceMult`) for the rest of that calendar
   day only, reverting automatically at the next day's rollover.
5. **Stuck-basket relief** (`InpUseStuckBasketRelief`, added 2026-07-27 after
   a real-tick backtest showed exactly this failure mode — see
   learnings.md): a basket that reaches max DCA legs has nowhere left to
   add, and with every stop-loss now off (see above), it would otherwise
   just sit open indefinitely waiting for the full `ProfitTarget` no matter
   how long that takes. Once a basket has been maxed out and stuck for
   `InpStuckBasketHours` (default 4h) with no target hit, its required
   profit linearly shrinks over the next `InpStuckBasketDecayHours`
   (default 8h) down toward `InpStuckBasketTargetFloor` (default `$0`,
   i.e. breakeven) — so it takes the first real exit chance instead of
   holding out for the original target. **This is not a guaranteed exit**:
   price still has to come back up to at least the floor for it to fire at
   all. It only shrinks *how much* bounce is required, not the chance that
   a bounce happens.

Tuned values persist across restarts via `GlobalVariableSet`/`Get`
(`InpResetTunedParams` wipes back to input defaults). Every decision is
logged to `MQL5/Files/GoldDualBasketDCA_tuning_log.txt` on the terminal
running it.

## Pyramiding — tried, removed permanently

Adding to a winning basket instead of closing it (riding a confirmed trend
for a bigger target) was tried in several forms and never beat the simpler
no-pyramid baseline in any tested combination (best case PF 0.75, worst
0.62, versus 0.92-0.95 without it) — converting target-hit "sure wins" into
extended, trend-riding exposure lost more often than it gained on every
tested week. Removed entirely per explicit request rather than left
disabled — see `learnings.md` for the full history if revisiting this idea.

## Backtest Results (1-week real-tick Strategy Tester runs, 2026.07.18-25)

| Config | Deposit | Profit Factor | Win rate | Net P/L | Max DD |
|---|---|---|---|---|---|
| Original spec defaults (0.01 lot, 4 legs, no trend filter) | $100 | 0.77 | 66.67% | -$12.39 | 19.16% |
| + trend filter (ATR-scaled, applied to bootstrap too) | $2000 | 0.71 | 78.33% | -$108.84 | 10.53% |
| + pyramiding | $2000 | 0.62-0.75 | 64-73% | -$165 to -$1087 | 14-26% |
| + lower max-loss ($220->$100) + higher target ($1->$2), no pyramid | $2000 | 0.92 | 79.34% | -$80.76 | 11.05% |
| Pushed the same two levers further ($2.50/$80) - worse, stopped tuning here | $2000 | 0.62 | 68.24% | -$165.69 | 14.03% |
| ATR-based dynamic DCA distance (`InpUseAtrDcaDistance=true`) | $2000 | 0.75 | 73.31% | -$234.58 | 14.24% |
| Daily loss limit **OFF** (stress test), older/smaller configs, x3 | $2000 | 0.81-0.82 | 65-74% | **-$2000+ (wiped)** | **100%+** |
| $5000 resize + deep AI brain, daily limit OFF | $5000 | 0.94 | 69.54% | -$365.85 | 12.35% |
| Daily limit OFF + hard-SL OFF + pyramid ON | $5000 | 0.69 | ~66% | -$1086.74 | 25.68% |
| Daily limit OFF + hard-SL OFF + pyramid OFF | $5000 | 0.93 | ~69% | -$334.82 | 21.78% |
| Pyramid removed + daily limit OFF + intraday soft-brake | $5000 | 0.95 | 71.68% | -$253.02 | 11.68% |
| + basket hard-SL OFF too (2026-07-19 to 07-26, real ticks) | $5000 | 1.02 | 71.13% | +$147.10 | 31.17% (equity) |
| + catastrophic backstop SL OFF too, i.e. every SL off (same week) | $5000 | 0.87 | 74.29% | -$562.03 | 35.76% (balance) / 34.54% (equity) |
| + stuck-basket relief added to AI brain (same week, still no catastrophic SL) | $5000 | 0.86 | 74.31% | -$579.05 | 35.85% (balance) / 34.63% (equity) |
| Catastrophic SL restored, 5 legs (same week) | $5000 | 1.02 | 71.13% | +$147.10 | 26.55% (balance) / 31.17% (equity) |
| **Catastrophic SL restored, 7 legs (current, same week)** | $5000 | **1.56** | **72.53%** | **+$2298.00** | **4.50% (balance) / 17.88% (equity)** |

**Historical note (superseded — see "Current state (2026-07-31, FINAL)" above
for what's actually shipped now)**: `InpInitialLot=0.02`, `InpLotMultiplier=1.5`,
`InpDcaDistancePrice=3.0` (fixed), `InpMaxLegsPerBasket=7`,
`InpBasketProfitTargetUSD=2.0`, `InpBasketMaxLossUSD=0.0` (basket hard-SL
**OFF**, per explicit request 2026-07-27), `InpUseDailyLimit=false`,
`InpUseIntradayBrake=true` (`InpIntradayBrakeLossPercent=3.0`). The
backtested-best config in the table above shipped with the basket hard-SL
ON (`150.0`) — removing it was a deliberate later request, not something
re-validated by backtest. With it off, a basket's only remaining loss
bound is the wide catastrophic backstop SL on each leg
(`InpUseCatastrophicSL`, `InpCatastrophicSLMultiple`) — everyday losses are
no longer capped by the tighter basket-level stop. Pyramid removed
permanently, daily circuit breaker traded for the softer intraday brake
per earlier explicit request. Still net-negative on the tested week (PF
0.95, not >1.0) even before this change — this is repeatedly-verified
progress, not a proven edge. **Do not keep tuning against this same
1-week window**; the honest next step is validating against a different
time period.

**On `InpUseDailyLimit=false`**: repeatedly stress-tested at the user's
explicit request. With the older, smaller-account configs it wiped the
account completely every time (100%+ drawdown, negative equity) — 3 runs in
a row, regardless of ATR-distance/pyramid on or off. With the new $5000
config and the deepened self-tuner (below), the account survived a fourth
attempt (12.35% drawdown) — real evidence the sizing/self-tuning is
healthier now, but **this does not mean the daily circuit breaker is safe
to leave off**; it means the basket-level and self-tuning layers are doing
more of the job than before. Ship with `InpUseDailyLimit=true`.

## Deep AI brain: persistent per-leg-depth history

Beyond the daily nudges to distance/multiplier/target, the self-tuner now
tracks **persistent** (not reset daily) win/loss counts at every leg depth a
basket has ever reached (`GetLegStat`/`IncrementLegStat`, keyed per-depth in
`GlobalVariable`s). Once a leg depth has enough samples
(`InpLegStatMinSample`), a win rate below `InpLegStatWinRateFloor` steps the
active max-legs cap (`g_tunedMaxLegs`) down (floor `InpMaxLegsFloor`); a win
rate above `InpLegStatWinRateCeil` lets it step back up, never past the
`InpMaxLegsPerBasket` ceiling. This is real accumulated evidence about
whether going deeper actually pays off, not just a fixed human-chosen number.

Also found and worth remembering: MT5's Strategy Tester caches an EA's
last-used inputs in `MQL5/Profiles/Tester/<EA>.set`, silently overriding
new compiled defaults on the next run unless explicitly passed via a
`[TesterInputs]` section in the launch `.ini` — cost two wasted test runs
(identical output to a prior run) before being caught.

## Setup

1. Open `Scalping Ai Pro By Farhan FX.mq5` in MetaEditor, compile (0 errors/
   warnings as of the last build).
2. Attach to an XAUUSD M1 chart on a **hedging-mode** account. Confirm
   `InpExpectedLogin` matches the account you intend to run on (or set to 0
   to skip the check).
3. Watch the on-chart dashboard for basket state, filter status, and
   self-tuned parameter values. Three buttons: `CLOSE ALL`, `Close BUY`,
   `Close SELL`.

## Next steps / not yet done

- Backtested extensively (1 week, real ticks, Strategy Tester) but **not yet
  run on a live/demo chart in real time** — watch the first few cycles
  closely (bootstrap entry, a forced DCA, a profit-target close+reopen)
  before leaving it unattended.
- Still net-negative on the tested week (PF 0.92) — validate against a
  different time period before trusting the current defaults, and don't
  keep tuning against this same week (see Backtest Results above).
- `InpDailyMaxLossPercent` (2.0%) hasn't itself been re-tuned for the bigger
  $2000+ account size this now assumes — revisit alongside any further
  account-size change.
