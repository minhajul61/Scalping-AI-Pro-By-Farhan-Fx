# XAUUSD Dual Basket DCA EA

File (final, permanent name per explicit request): **`Scalping Ai Pro By
Farhan FX.mq5`** / `.ex5`. Note this is the same name as the separate,
unrelated Python ML project at `E:\Scalping AI Pro By Farhan Fx` — the user
was told this explicitly and confirmed the name anyway, so it's
intentional, not a mix-up. This repo/folder (`XAUUSD Dual Basket DCA EA`)
and everything in it is the native MQL5 grid/DCA EA documented below; it
has no code relationship to that other project.

Every position this EA opens is tagged with magic number `InpMagicNumber`
(default `20270115`) and a trade comment like `GDSE-buy-leg1` /
`GDSE-sell-leg3` (visible in MT5's Trade/History "Comment" column) —
`GDSE` is just the internal short prefix, distinct per leg number and
direction so it's easy to tell legs apart at a glance.

Native MQL5 Expert Advisor for XAUUSD (M1). Runs a BUY basket and a SELL
basket simultaneously (requires a **hedging-mode** MT5 account). Each basket
targets a floating-profit dollar amount, closes, and immediately reopens. On
an adverse price move past the last leg, adds a martingale DCA leg — capped,
filtered, and safety-netted (see below) after this user's prior similar EA
(`E:\Straddle Ai Buy Sell Pending EA\StraddleAI_EA.mq5`) blew up a demo
account with uniform lot sizing, no leg cap, and no floating-loss circuit
breaker.

## Core logic

- Bootstrap: if a basket is empty, open one `InpInitialLot` leg.
- Profit target: once a basket's summed floating P/L reaches
  `InpBasketProfitTargetUSD`, close every leg in that basket and reopen fresh.
- DCA: if price moves `InpDcaDistancePrice` adverse past the basket's last
  leg, add another leg sized at `InpLotMultiplier`x the initial lot (per leg
  count, not compounded off the previous leg, to avoid rounding drift), up to
  `InpMaxLegsPerBasket` legs.
- DCA filters: skips the add if `IsAtrSpiking()` (a volatility-spike "news
  proxy" — real economic-calendar integration wasn't wanted) or if
  `InpUseTrendFilter` finds a strong higher-timeframe trend against the
  basket's direction.

## Safety (beyond the original spec — added deliberately)

- `InpBasketMaxLossUSD`: hard stop-loss per basket, independent of the leg
  cap — a maxed-out basket that keeps losing otherwise has no exit.
- `InpBasketSLCooldownMinutes`: after a hard-SL close (not a profit-target
  close), the basket waits before reopening rather than instantly re-entering
  into the move that just stopped it out.
- `InpUseCatastrophicSL`: a wide backstop SL attached to every leg at order
  time — invisible in normal operation, only matters if the EA/VPS stops
  running and nothing is left enforcing the basket-level stop.
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

**On `InpUseDailyLimit=false`**: stress-tested repeatedly. With earlier,
smaller-account configs it wiped the account completely every single time
(100%+ drawdown, negative equity) — 3 runs in a row. It is a real,
meaningful safety layer being deliberately given up per explicit request,
not a redundant one. The intraday soft-brake below is a genuine mitigation,
not an equivalent guarantee.

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
3. **Intraday soft-brake** (added when the daily circuit breaker was turned
   off by default): NOT a hard stop or force-close. Once today's floating
   loss crosses `InpIntradayBrakeLossPercent` (default 3%), it caps the lot
   multiplier down (`InpIntradayBrakeMultiplierCap`) and widens the DCA
   distance (`InpIntradayBrakeDistanceMult`) for the rest of that calendar
   day only, reverting automatically at the next day's rollover.

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
| **Pyramid removed + daily limit OFF + intraday soft-brake (current)** | $5000 | **0.95** | **71.68%** | **-$253.02** | **11.68%** |

**Current shipped defaults**: `InpInitialLot=0.02`, `InpLotMultiplier=1.5`,
`InpDcaDistancePrice=3.0` (fixed), `InpMaxLegsPerBasket=5`,
`InpBasketProfitTargetUSD=2.0`, `InpBasketMaxLossUSD=150.0`,
`InpUseDailyLimit=false`, `InpUseIntradayBrake=true`
(`InpIntradayBrakeLossPercent=3.0`). This is the best result found across
every tested combination — real-tick verified, hard-SL kept ON (removing it
increases drawdown a lot for little-to-no PF gain — see table), pyramid
removed permanently, daily circuit breaker traded for the softer intraday
brake per explicit request. Still net-negative (PF 0.95, not >1.0) and
still one week of data — this is repeatedly-verified progress, not a proven
edge. **Do not keep tuning against this same 1-week window**; the honest
next step is validating against a different time period.

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
