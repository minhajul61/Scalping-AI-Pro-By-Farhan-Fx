# XAUUSD Dual Basket DCA EA

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
