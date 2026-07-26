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

- Only manually reasoned through the logic and confirmed a clean compile —
  has not yet been run on a live/demo chart. Watch the first few cycles
  closely (bootstrap entry, a forced DCA, a profit-target close+reopen)
  before leaving it unattended.
- Strategy Tester validation (this design should backtest cleanly, unlike
  EAs using the real economic calendar, since the DCA filters are ATR/MA
  based) — not yet run.
- `InpBasketMaxLossUSD` (15.0) and `InpDailyMaxLossPercent` (2.0) defaults
  are reasonable starting guesses for a small demo account, not tuned to any
  specific account size — revisit before scaling up lot sizes or moving to
  a live account.
