# Gold Dual Basket DCA EA

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
- Daily circuit breaker (`InpUseDailyLimit`), force-closes both baskets by
  default (`InpDailyLimitForceCloses = true`) rather than just halting new
  entries, given this EA's higher martingale risk profile.

## Self-tuning "AI brain"

Native MQL5 has no ML libraries, so this is a **rule-based daily self-tuner**
(confirmed with the user as the realistic scope), not a trained model. Once
per new day, reviews yesterday's closed trades (grouped into basket-close
"cycles") and nudges `DcaDistance` / `LotMultiplier` / `ProfitTarget` within
bounded ranges — conservative by design: only widens distance / lowers
multiplier on real trouble signals (baskets maxing out and still losing),
never tightens risk just because a good day happened. Tuned values persist
across restarts via `GlobalVariableSet`/`Get` (`InpResetTunedParams` wipes
back to input defaults). Each day's decision is logged to
`MQL5/Files/GoldDualBasketDCA_tuning_log.txt` on the terminal running it.

## Pyramiding (present in code, off by default)

`InpUsePyramid` adds to a winning basket instead of closing it, at the exact
moment its target is hit, if the higher-timeframe trend still strongly
confirms that direction (decided in `ManageBasketExits`, not a separate
distance trigger — an earlier version's own `$` distance trigger never fired
because the base target closes the basket at a far smaller move first).
Backtested worse than not pyramiding (see Backtest Results) — converting
target-hit "sure wins" into extended, trend-riding exposure lost more often
than it gained on the tested week. Left in the code, off by default
(`InpUsePyramid = false`), in case a different market period favors it.

## Backtest Results (1-week real-tick Strategy Tester runs, 2026.07.18-25)

| Config | Deposit | Profit Factor | Win rate | Net P/L | Max DD |
|---|---|---|---|---|---|
| Original spec defaults (0.01 lot, 4 legs, no trend filter) | $100 | 0.77 | 66.67% | -$12.39 | 19.16% |
| + trend filter (ATR-scaled, applied to bootstrap too) | $2000 | 0.71 | 78.33% | -$108.84 | 10.53% |
| + pyramiding | $2000 | 0.62-0.64 | 64.83% | -$165.69/-$166.43 | 14.03-14.20% |
| + lower max-loss ($220->$100) + higher target ($1->$2), no pyramid | $2000 | 0.92 | 79.34% | -$80.76 | 11.05% |
| Pushed the same two levers further ($2.50/$80) - worse, stopped tuning here | $2000 | 0.62 | 68.24% | -$165.69 | 14.03% |
| ATR-based dynamic DCA distance (`InpUseAtrDcaDistance=true`) | $2000 | 0.75 | 73.31% | -$234.58 | 14.24% |
| Daily loss limit **OFF** (stress test) x3, various configs above | $2000 | 0.81-0.82 | 65-74% | **-$2000+ (wiped)** | **100%+** |
| **$5000 config below + deep AI brain, daily loss limit OFF (stress test)** | $5000 | **0.94** | 69.54% | **-$365.85** | **12.35%** |

**Current shipped defaults**: `InpInitialLot=0.02`, `InpLotMultiplier=1.5`,
`InpDcaDistancePrice=3.0` (fixed, `InpUseAtrDcaDistance=false` — ATR mode
backtested worse), `InpMaxLegsPerBasket=5`, `InpBasketProfitTargetUSD=2.0`,
`InpBasketMaxLossUSD=150.0`, `InpDailyMaxLossPercent=5.0`,
`InpUsePyramid=false`. Derived from a systematic search (not guessed) for a
config where the full 5-leg worst-case floating loss is a small, comfortable
fraction of a bigger ($5000) account (-$96, 1.92%) with an easy bounce back
to target from there (~$3.77) — see `learnings.md` for the full search
table. Still net-negative even in the best row (PF 0.94, not >1.0) — this is
progress, not a proven edge. **Do not keep tuning against this same 1-week
window**; the honest next step is validating against a different time
period.

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

1. Open `GoldDualBasketDCA.mq5` in MetaEditor, compile (0 errors/warnings as
   of the last build).
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
