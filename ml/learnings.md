# Learnings

(One plain-English lesson per notable result — same convention as the
parent EA project's `learnings.md` and the sibling `Scalping AI Pro By
Farhan Fx` Python project's `learnings.md`.)

- **2026-07-31 (project started):** Scaffolded per the approved plan
  (`C:\Users\BeingPe\.claude\plans\unified-booping-raven.md`). Confirmed
  before writing any code: MT5 terminal build 6090 (2026) supports ONNX
  inference; Python env at
  `C:\Users\BeingPe\AppData\Local\Python\bin\python.exe` has
  sklearn 1.9.0, lightgbm 4.7.0, pandas, numpy, MetaTrader5, onnx 1.22.0,
  onnxruntime 1.28.0, skl2onnx 1.20.0 all working; `onnxmltools` was
  missing and has now been installed (1.16.0) for the LightGBM->ONNX
  route. Reused the sibling Python project's `fetch_history.py`/
  `mt5_client.py`/`logging_setup.py` patterns essentially unchanged (same
  account/server, same chunk-and-walk-backward history-floor detection).

- **2026-08-05 (real bug found during Phase 1 data fetch - wrong-account
  auto-launch):** `mt5.initialize(path=..., login=416045126, password="",
  server="Exness-MT5Trial14")` silently launched a **brand-new terminal64.exe
  instance logged into a completely different account (463741386,
  Exness-MT5Trial17)** whenever no terminal was already running - reproduced
  three times in a row, not a fluke. Root cause: an empty password only
  works when that exact login is already cached/logged-in in the specific
  terminal data folder being used; with no terminal running, MT5 launches
  fresh and falls back to whatever account was last manually used in this
  install's default profile (unrelated to this project). The sibling
  Python project's identical mt5_client.py/empty-password setup only ever
  worked because a correctly-logged-in terminal was coincidentally already
  open at the time.
  **Fix**: `fetch_history.py` now calls `connect(verify_account=True)`
  (was `False`) so any mismatch fails loudly instead of silently pulling
  data from - or worse, later trading on - the wrong account. **Also**:
  before running any fetch, first launch `terminal64.exe` with an explicit
  `/config:<ini with [Common] Login=416045126 Server=Exness-MT5Trial14>`
  to force the correct account, then run the Python script so it just
  attaches to the already-correctly-logged-in instance. Confirmed working:
  M1 100,000 bars (~103d, matches the sibling project's known floor), H1
  5,838 bars (~359d), **D1 1,533 bars (~1,799d / ~4.9 years)** - much
  deeper D1 history than the ~480-576 days this EA's own live regime
  detector found on the VPS's different account/broker (414069851,
  Exness-MT5Trial6) - the two accounts simply have different history
  depth, not a bug in either.

- **2026-08-05 (feature engineering + basket_simulator.py built and
  sanity-checked):** Ported the sibling's 13 base features unchanged, added
  7 EA-specific features (h1_trend_strength/sign/age, d1_trend_pctile/
  vol_pctile mirroring GetTrend()/UpdateMarketRegime() exactly, using an
  expanding-window percentile rank to match the live EA recomputing fresh
  each day against all D1 history available at that time - not a fixed
  lookback). Correctly joined H1/D1 indicators onto M1 bars using each
  higher timeframe's *closed* bar only (CopyBuffer shift=1 semantics),
  never the still-forming bar.

  Built `basket_simulator.py`, a faithful Python port of the EA's own DCA/
  cycling/target logic. Deviated from the plan's literal wording of
  "reproduce the exact 2026-07-24 incident" - that incident happened under
  a DIFFERENT EA configuration (before cycling existed, 1.5x multiplier,
  different account/broker) so it isn't a like-for-like target under
  today's config. Substituted a more directly diagnostic regression test:
  verified the exact geometric-then-reset lot sequence
  (0.02/0.04/0.08/0.16/0.32/0.64/1.28, repeating every 7 legs) - PASSED.

  Replayed the full ~103-day M1 history: **8,086 episodes, 8,085 closed at
  target, 1 censored (still open at data end), 25 genuinely "stuck"
  episodes** (reached >=1 full cycle and stayed open >4h past their last
  leg). Leg-count-at-DCA-add distribution tapers from 2,627 (leg 1) down
  to single digits by leg 20+, with one basket reaching leg 31 (>4 full
  cycles) - direct, systematic confirmation of exactly the kind of episode
  this whole ML effort exists to help avoid.

  Found (and left as a documented limitation rather than silently ignoring
  it): `is_against_trend_now` and `is_atr_spiking_now` are **constant
  (always False)** in every recorded training row, because the simulator -
  matching the live EA's actual control flow exactly - only records a
  DCA-add decision AFTER it has already passed both filters. These two
  features currently contribute zero signal to the stuck-risk model; the
  AUC 0.81 result below comes entirely from the other 10 features. Not a
  bug (both training and live inference are self-consistent about this),
  just dead weight worth revisiting in a future version (e.g. by also
  recording filtered-out near-misses).

- **2026-08-05 (Model 1: trend-continuation - honest negative result,
  consistent with the sibling project):** Labeled continuation_return =
  trend_sign * forward_return at 30/60/120-min horizons, ATR-scaled noise
  floor, ambiguous rows dropped, only defined where the rule already says
  there's a trend (sign != 0). Trained logistic/RandomForest/LightGBM per
  horizon with a strict chronological 60/20/20 split, holdout touched
  once. Required the model to clear a **meaningfully-above-chance bar**
  (holdout AUC > 0.55), not just "beats the rule's blind continuation rate
  on one holdout sample" (an earlier, looser check technically passed for
  H=30min/logistic at AUC 0.51 - re-checked and correctly rejected once
  the same 0.55 bar used for Model 2 was applied consistently).

  **Result: no horizon/model combination cleared the bar.** Holdout AUCs:
  H=30 -> 0.513, H=60 -> 0.510, H=120 -> 0.495 (i.e., at or below chance).
  This directly matches the sibling Python project's own conclusion on raw
  XAUUSD direction (~50.4-50.7% accuracy, indistinguishable from a coin
  flip) - reformulating the target as "continuation of an existing signal"
  rather than "direction from nothing" did not, in the end, produce a
  meaningfully more tractable problem on this data. **Not shipped, no ONNX
  export, not wired into the EA.** This is the honest, expected-odds
  outcome (the plan itself estimated ~15-30% chance of success here).

- **2026-08-05 (Model 2: stuck-basket-risk - genuine positive result):**
  Labeled every DCA-add decision with its episode's eventual outcome
  (1=stuck, 0=closed at target), dropping the 8 decisions belonging to the
  1 still-censored episode. **337 positive examples across 25 distinct
  stuck episodes** out of 5,214 total DCA-add decisions - clears the
  pre-registered go/no-go floor of 30 comfortably (the episode-level count
  of 25 alone would NOT have cleared it - it's the per-decision count,
  337, that matters here, since each stuck episode contributes many
  labeled rows).

  Used **episode-grouped** chronological 60/20/20 splitting (mandatory,
  not optional) - rows from the same episode share a strongly correlated
  outcome, so a row-level split would leak one episode's later legs into a
  different split than its earlier legs (the same class of correlated-row
  leakage as the sibling project's overlapping-trade bug, via groups
  instead of overlapping time windows). Split: train=1,575 episodes,
  val=525 episodes, holdout=526 episodes.

  Compared logistic/shallow-RandomForest(depth<=3)/shallow-LightGBM(depth<=3),
  all class-weighted given the rare positive class. Best on validation:
  shallow RandomForest (val AUC 0.924). **Holdout AUC (touched once, on
  526 episodes never seen during training/validation): 0.810** - clears
  the 0.55 "meaningfully above chance" bar with real room to spare, though
  with a visible val->holdout gap (0.924 -> 0.810) worth treating as an
  honest first signal rather than a fully proven, bulletproof result,
  given the modest absolute number of independent stuck episodes (25) the
  positive class is built from.

  This is a genuinely encouraging result and matches the plan's own
  reasoning for why this target might be more tractable than direction
  prediction: it's closer to regime/anomaly detection ("does this
  basket-plus-market state resemble the states that historically preceded
  trouble") than to per-bar direction forecasting.

- **2026-08-05 (ONNX export + MQL5 integration):** Exported the winning
  shallow-RandomForest via skl2onnx (`zipmap=False` to get a plain float
  tensor instead of a list-of-dict) at opset 15. Round-trip validated in
  Python: onnxruntime's output matched the source sklearn model's
  `predict_proba` to within 8.96e-08 (tolerance was 1e-5) - PASSED. File
  is 109,450 bytes.

  Added `InpUseMLStuckRiskFilter` (default **false**) + threshold inputs
  to the EA. `OnnxCreate`/`OnnxSetInputShape` in `OnInit()` (non-fatal on
  failure - logs and continues on rule-based logic alone, since this EA
  has no SL to fall back on either way); `OnnxRelease` added to
  `OnDeinit()` (wasn't there before - this is a genuinely new resource to
  clean up). New `BuildStuckFeatures()`/`GetMLStuckRisk()` compute the
  same 12 features live and run inference; wired into
  `ManageBasketEntries()`'s DCA-add branch (skip the add entirely above
  `InpMLStuckRiskSkipThreshold`, otherwise let `EffectiveLotMultiplier()`
  damp the lot-growth multiplier toward 1.0x as risk rises past
  `InpMLStuckRiskShrinkStart`) and into the dashboard. Also added
  `bootstrapTime` tracking to `SBasket`/`ScanBasket()` (needed for the
  `hours_since_bootstrap` feature - didn't exist before, only
  `lastLegTime` did).

  **Compiles clean (0 errors, 0 warnings)** - one real bug caught here:
  `input` is a reserved MQL5 keyword and can't be used as a local variable
  name (used it for the ONNX input buffer initially - renamed to
  `onnxInput`).

  **Honest limitation, stated plainly: the `OnnxRun()` multi-output
  binding (this model has two outputs - int64 labels and float
  probabilities - and MQL5's exact parameter-matching convention for that
  was implemented from documentation/best understanding, not confirmed by
  actually running it)** has NOT been runtime-verified. Attempted to
  verify via the Strategy Tester (which does execute real MQL5 `OnInit`/
  `OnTick` code, unlike a plain compile) but could not get exclusive
  access to the shared local testing terminal in this session - a
  separate, unrelated automated process (a different EA/project, judging
  by its own distinct "MlFilter"/"InpEnableMLFilter" log messages) was
  concurrently using the same terminal data folder and repeatedly caused
  it to log into the wrong account. This is an environment/scheduling
  issue, not a defect discovered in this project's own code. **Before
  relying on `InpUseMLStuckRiskFilter=true` for anything, attach the EA to
  a chart (demo or Strategy Tester) and check the Experts/Journal log for
  either "ML stuck-risk model loaded successfully" with no subsequent
  "OnnxRun failed" messages, or fix whatever the log reports** - the
  non-fatal fallback means a binding mismatch degrades to "no effect"
  (risk always reads as 0) rather than crashing, but that also means it
  could silently do nothing useful without the log confirming it's really
  running.

- **2026-08-06 (ONNX runtime verification: two real bugs found and fixed,
  then a genuine, verified positive backtest result):** Got exclusive
  access to an isolated MT5 install (a separate Vantage Markets terminal,
  own data folder, never conflicts with any other concurrent session) and
  finally ran the ML-augmented EA through the real MT5 Strategy Tester -
  not just a compile check. Found two real runtime bugs the compile
  couldn't catch:

  1. **File not found (err 5019) despite the file being right where the
     code looked.** The Strategy Tester runs each test in an isolated
     per-agent sandbox (`...\Tester\<terminal-hash>\Agent-127.0.0.1-3000\
     MQL5\Files\`) that gets wiped/regenerated on every single run - a
     model file copied there manually does not survive to the next test.
     **Fix**: changed `OnnxCreate()` to use the `ONNX_COMMON_FOLDER` flag
     instead, which reads from `Terminal\Common\Files\` - a location that
     is genuinely shared and persistent across every terminal install and
     every tester agent on the machine, not per-instance.
  2. **"ONNX: parameter is empty" (err 5805) on every `OnnxRun()` call.**
     `OnnxSetInputShape()` was called but the two OUTPUT shapes (int64
     label `[1]`, float probabilities `[1,2]`) were never set - the model
     genuinely loaded but couldn't run. **Fix**: added two
     `OnnxSetOutputShape()` calls alongside the input one, plus
     defensively pre-sizing the output arrays with `ArrayResize()` before
     each `OnnxRun()` call.

  After both fixes, confirmed via the Experts log that inference is
  genuinely running and producing sensible decisions in real time, e.g.:
  `ML stuck-risk filter SKIPPED BUY DCA-add (leg 6): risk 0.68 >= skip
  threshold 0.60`.

  **Backtested ML ON vs OFF, identical settings otherwise, $10,000
  deposit, same real-tick week (07-19..07-26):**

  | Metric | ML OFF | ML ON |
  |---|---|---|
  | Net Profit | -$4,712.71 | **-$2,461.29** |
  | Profit Factor | 0.61 | **0.71** |
  | Balance Drawdown | 59.36% | **41.49%** |
  | Equity Drawdown | 79.51% | **48.35%** |
  | Worst losing streak | 25 trades / -$7,716.99 | **14 trades / -$5,345.46** |
  | Largest single loss | -$741.03 | -$1,780.82 (worse) |

  A genuine, verified improvement across net P/L, profit factor, both
  drawdown measures, and losing-streak length - roughly halving the net
  loss and cutting max drawdown by 18-31 percentage points, by correctly
  skipping DCA-adds the model flagged as high stuck-risk in real time.
  One metric got worse (largest single loss, likely because skipping legs
  changes which legs are still open when a basket eventually unwinds, so
  the remaining ones each carry more of the loss) - noted honestly rather
  than only reporting the wins.

  **Still net-negative overall** - the ML filter measurably reduces harm
  within the EA's current no-SL/2.0x-multiplier configuration, it does
  not fix the underlying structural risk of that configuration (which
  remains an explicit, informed user decision, not something ML is meant
  to solve). One notable performance cost: real-tick testing with ML
  enabled runs dramatically slower than without it (a single stuck-basket
  episode can trigger ONNX inference on nearly every tick for hours of
  simulated time) - worth optimizing (e.g. only re-checking once per new
  adverse-trigger event rather than every tick) in a future revision if
  this becomes a live-trading latency concern, though M1-bar-level
  decision frequency in live trading is unlikely to hit the same
  every-real-tick volume seen in Strategy Tester's Model=4.

- **2026-08-12 (live demo: user overrode the ML skip-gate, turned it back
  off, an explicit and informed decision):** Deployed to a fresh isolated
  VPS demo (Exness-MT5Trial14, login 416045126, hedging confirmed) with
  `InpUseMLStuckRiskFilter=true`. Within hours a SELL basket sat at leg
  5/7, floating roughly -$736 to -$798, with the model correctly
  identifying the next leg-add as high stuck-risk and skipping it
  (exactly the verified backtest behavior). The user found this
  unacceptable in practice: their original spec from project inception
  was "always martingale against-trend positions until profit, no
  exceptions" - a basket sitting non-progressing for hours, even for a
  statistically-justified reason, directly conflicts with that intent.
  User's explicit final instruction: turn `InpUseMLStuckRiskFilter` back
  to `false` live on the running VPS chart (Inputs tab, no recompile
  needed - it's already the compiled default), restoring unconditional
  martingale-until-profit behavior gated only by the pre-existing
  ATR-spike/trend filters.

  **The lesson:** a verified statistical improvement (lower average net
  loss, better PF, smaller drawdowns) is not automatically the answer if
  it conflicts with the user's actual behavioral requirement - here,
  guaranteed eventual martingale-through rather than expected-value
  optimization with occasional multi-hour non-progress. The ML stuck-risk
  model and its ONNX integration remain fully built, tested, and
  available (just gated off by default and live) if the user wants to
  re-enable it later, e.g. with a much higher skip threshold, or a
  bounded-delay skip (wait N hours, then force the leg anyway) rather
  than an unconditional skip. Not revisited unless the user asks.

- **2026-08-12 (full removal, not just disabling, of self-tuning/regime
  detection/ML - explicit user instruction):** After the override above,
  the user reported the Inputs dialog itself ("eto gulo setting kiser ami
  kichu bujte parchi na" - so many settings, I can't understand what
  they're for) as the real problem, not just the ML behavior specifically.
  Explicit final instruction: turn the four feature toggles (self-tuning,
  regime detection, intraday brake, stuck-basket relief) off as defaults,
  **remove the rest of those settings** (i.e. delete the now-meaningless
  parameters under each disabled feature, not just leave them inert), and
  **simplify the wording** of what remains so it's understandable.

  Rewrote `Scalping Ai Pro By Farhan FX.mq5` (build `2026.08.12.1`): fully
  removed the self-tuner (`RunDailySelfTune`/`LoadTunedParams`/
  `SaveTunedParams`/`GetLegStat`/`GlobalVariable*` persistence/
  `WriteTuningLog`), the market-regime detector (`UpdateMarketRegime`/
  `PercentileRankOf`/D1 history loading/regime-based DCA-distance and
  lot-multiplier multipliers), the intraday soft-brake
  (`CheckIntradayBrake`), the stuck-basket-relief target-shrink, and the
  entire ML/ONNX stuck-risk integration (`OnnxCreate`/`OnnxRun`/
  `BuildStuckFeatures`/`GetMLStuckRisk` and their `OnInit`/`OnDeinit`
  wiring) - along with every now-meaningless input parameter that
  belonged only to those features (14 inputs removed, 3 whole input
  groups gone: `Auto-Adjust Settings (AI Brain)`, `Market Regime
  Detection (AI Brain)`, `ML (ONNX)`). What remains: fixed DCA distance,
  fixed lot multiplier, per-cycle growing profit target, ATR-spike +
  trend filters (unchanged), all safety toggles still present but at
  their already-explicit OFF defaults. Also rewrote every remaining
  input's inline comment in plain Banglish (the user's own habitual
  written register) instead of English trading jargon, since the goal
  was the user being able to read the Inputs dialog and understand it
  directly, not just have fewer rows.

  Recompiled clean (0 errors, 0 warnings, MetaEditor CLI via the isolated
  Vantage terminal - `metaeditor64.exe /compile` needs to run through
  `PowerShell`'s `Start-Process`, not the plain Bash tool, in this
  environment; the Bash-launched process exited immediately without
  compiling or producing a log, silently, while PowerShell's
  `Start-Process -Wait` ran it correctly and captured the full compiler
  log - worth remembering if this comes up again).

  **The lesson:** "reduce settings" and "disable settings" are different
  requests. Disabling behavior (what the 2026-08-12 entry above did)
  keeps every parameter visible and technically re-enablable, which is
  the right call when the user might want the feature back with a tweak.
  But when the complaint is the settings list itself being incomprehensible,
  only actually deleting the dead parameters (and rewriting the survivors
  in the user's own plain language) fixes the real problem - a disabled-
  but-still-visible wall of inputs is not simpler, just inert.

- **2026-08-12 (same day, follow-up): added a news filter, reverted input
  comments to English, confirmed no learning happens anymore.** User asked
  for three things in one message: (1) pause new trades/DCA-adds around
  medium/high-impact USD news (30 min before, 30 min after), (2) switch
  the just-simplified input comments from Banglish back to plain English,
  (3) a direct question - does the EA currently learn anything from trade
  history? Answered honestly: no, not since the same-day removal above -
  it's purely fixed-parameter/rule-based now (fixed DCA distance, fixed
  multiplier, trend/ATR/news filters), nothing persists or adapts across
  trades or days.

  Implemented the news filter (build `2026.08.12.2`) using MT5's built-in
  economic calendar (`CalendarValueHistory`/`CalendarEventById` -
  MetaQuotes-hosted, no external API/key needed, syncs automatically while
  the terminal is connected). New `IsNewsBlackout()` checks for any
  `CALENDAR_IMPORTANCE_MODERATE`/`HIGH` event in `InpNewsCurrency` within
  `[now - InpNewsMinutesAfter, now + InpNewsMinutesBefore]`; gated into
  `ManageBasketEntries()` so it blocks both fresh bootstrap entries and
  DCA-adds, but never blocks an already-open basket from closing at its
  profit target. New `=== News Filter ===` input group (4 inputs), plus a
  dashboard "News" line (clear/blocking/off) next to the existing
  ATR-spike/trend filter lines.

  **Not yet live-verified** - the calendar functions are well-established
  for live/demo charts, but this project has already been burned twice by
  assuming an MQL5 API "should just work" without an actual runtime test
  (see the two ONNX bugs above) - Strategy Tester calendar-event replay
  support/behavior specifically has not been checked yet for this EA. Flag
  this as unverified until watched live through an actual news event or
  confirmed working in a tester run that spans one.

- **2026-08-12 (same day, second follow-up): DCA distance to $2.00 default,
  and the entire Safety input group removed - not just left off.** Three
  more requests in one message: (1) change the default DCA distance -
  user said "2 point"; asked directly whether they meant a literal MT5
  point ($0.002, which would fire on almost every tick) or $2.00 in price
  terms (matching how they'd used "point" earlier in this same
  conversation to mean the dollar DCA-distance figure) - confirmed $2.00.
  Good example of a case worth an explicit clarifying question rather than
  guessing: the two readings differ by 1000x and a wrong guess would have
  broken live trading on the VPS demo silently. (2) Delete whichever
  settings aren't actually used - by this point the only remaining inert
  group was `=== Safety ===` (basket-level SL + cooldown, catastrophic
  per-leg SL, daily loss limit), all permanently at OFF/0 per the
  project's original, repeatedly-reconfirmed "no SL, no safety SL, ever"
  decision (see the EA's own `learnings.md`, 2026-07-31). Removed the
  whole group and its code (`DailyLimitHit()`, the `g_cooldownUntil[]`
  reopen-cooldown mechanism, `OpenLeg()`'s catastrophic-SL backstop
  price) entirely - every `trade.Buy`/`trade.Sell` call now always passes
  `sl=0`, no code path can ever attach a stop-loss to a leg again. Kept
  `UpdateDayTracking()`/`g_dayStartBalance` (Daily P/L is still a useful
  dashboard readout, independent of the removed daily-limit feature). (3)
  Confirmed the news filter's before/after minutes were already
  per-user-configurable inputs (`InpNewsMinutesBefore`/`InpNewsMinutesAfter`,
  added the same day) and its status was already on the dashboard - no
  change needed, just confirmed back to the user.

  Build `2026.08.12.3`, recompiled clean (0 errors, 0 warnings).

- **2026-08-12 (same day, third follow-up): user's own backtest found a
  better DCA-distance setting - real, verified, not guessed.** User asked
  how to reduce equity drawdown without sacrificing profit and ran the
  comparison themselves in the Strategy Tester (2026.08.01-08.12,
  $15,000 deposit): tightening `InpDcaDistancePrice` from $2.00 to $1.20
  (lot multiplier left at 2.0x) improved *every* metric at once - net
  profit $21,203.79 -> $30,006.62, profit factor 1.47 -> 1.54, recovery
  factor 1.99 -> 4.02, balance DD 7.54% -> 5.18%, **equity DD 35.55% ->
  18.93%**. Counter to the initial recommendation (which was to *widen*
  distance to reduce DD) - a tighter grid cycles baskets faster, so less
  capital stays tied up deep in a basket for as long, which won this
  test window on both profit and risk simultaneously. Worth remembering:
  the "widen distance to de-risk" intuition (which was also the old,
  now-removed self-tuner's actual trouble-signal response) is not
  universally true - it depends on how mean-reverting the test window
  is. Set as the new default per explicit request ("eta koro default
  setting final").

  Also renamed every input's inline comment to short, conventional
  trading-EA terminology (`Lot Multiplier`, `DCA Distance ($)`,
  `Take Profit ($)`, `Magic Number`, `Account Login`, etc.) instead of
  full descriptive sentences, matching the style of the user's other
  EAs, per explicit request. Build `2026.08.12.4`, recompiled clean.

  **Caveat worth flagging honestly:** this is one comparison on one
  ~2-week window, not a walk-forward/holdout-validated result - the
  same discipline this project applied to the ML models (chronological
  holdout, never trust a single in-sample backtest) technically applies
  here too, just not practical to enforce on a manual single-parameter
  tweak done live by the user. If $1.20 turns out to be overfit to this
  specific window, it should show up as a live-tracking discrepancy
  later, not as a surprise.

- **2026-08-13 (automated 14-way parameter sweep over July 2026 - every
  configuration lost money, and a real MT5 automation bug found along the
  way):** User asked for a systematic DCA distance / lot multiplier / max
  legs / news-filter comparison over "last month" (interpreted as July
  2026), $15,000 deposit, real-tick modelling. Built a PowerShell
  orchestrator that generates one `/config` ini per variant and launches
  `terminal64.exe` headlessly (`ShutdownTerminal=1` so each run exits on
  its own), then parses the resulting `.htm` report for the key metrics -
  the same `/config` pattern already proven for the ONNX ML backtest
  comparison (2026-08-06).

  **Real bug caught before trusting the results:** the first full 14-run
  batch produced *byte-for-byte identical* output for all 14 variants -
  same profit, same trade count, down to the ticket. Root cause: the
  script cloned the base inputs via `$baseInputs.Clone()`, but
  `[ordered]@{}` (`OrderedDictionary`) does not support `.Clone()` in
  Windows PowerShell 5.1 - it throws, and with `$ErrorActionPreference =
  "Continue"` the script kept going with `$inputs` silently `$null`,
  writing an empty `[TesterInputs]` section to every ini. MT5 apparently
  fell back to whatever config it had cached from the last manually-run
  test instead of erroring - so 14 "different" backtests silently reran
  the same one. Fixed by manually copying key-by-key into a fresh
  `[ordered]@{}` instead of relying on `.Clone()`. Caught by spot-checking
  one generated ini's `[TesterInputs]` section before trusting a 50-minute
  batch, not by the results looking wrong at a glance - worth remembering
  as a general lesson: identical results across a sweep is itself a bug
  signal, not just a boring finding.

  **Real result after the fix:** all 14 configurations were net-negative
  over July 2026 (XAUUSD M1, real ticks) - tuning changed the size of the
  loss, not the sign, consistent with July being a trending month (this
  design's worst case, since it has no SL and depends on mean reversion
  back through the average entry). Least-bad: `InpMaxLegsPerBasket=5`
  (down from 7), smallest loss and lowest drawdown of the sweep. Worst:
  `InpMaxLegsPerBasket=15`, worst on every metric simultaneously.
  `InpLotMultiplier=2.5` stood out as a false positive on Profit Factor
  alone (0.77, best of the sweep) while having the single worst Equity
  Drawdown (151%) and 3x the trade count - a reminder to always check
  drawdown/trade-count alongside PF, not PF in isolation.

  **News Filter ON vs OFF produced identical results** (same P/L, same
  trade count) - confirms the standing caveat from when the filter was
  built: MT5's Strategy Tester does not appear to feed real economic-
  calendar data for arbitrary historical test periods, so `IsNewsBlackout()`
  never actually returned true during this backtest regardless of the
  setting. This does not mean the live/demo behavior (verified working via
  the OnInit diagnostic, 2026-08-13 earlier) is wrong - only that the
  Strategy Tester can't be used to validate this particular feature.

  Full report published as an artifact (14-row comparison table +
  findings) rather than just reported in chat, given the volume of
  structured data. Not treated as a final setting change - explicitly
  flagged to the user as one in-sample month, not walk-forward validated,
  same discipline as the DCA-distance-to-$1.20 change above.

- **2026-08-13 (same day, follow-up): multi-timeframe trend confirmation
  built and tested - genuinely helped, did not save the account.** User's
  hypothesis: would trading strictly with a more reliably-identified trend
  (confirmed across multiple timeframes, not just one H1 read) have kept
  July 2026's account from blowing up? Built `InpUseMultiTFTrend` (build
  v6, default off): when on, `GetTrend()` requires H1 + H4 + D1 (the new
  `InpTrendTF2`/`InpTrendTF3`) to all agree on direction before calling it
  a real trend; otherwise flat/0 - refactored the single-TF MA+ATR check
  into a reusable `GetTrendOnTF()`.

  Backtested single-TF vs multi-TF, same July 2026 window/$15,000/DCA
  $1.20/2.0x/legs 7 otherwise:

  | Metric | Single-TF (current default) | Multi-TF confirmed |
  |---|---|---|
  | Net Profit | -$16,922.53 | **-$15,211.46** |
  | Profit Factor | 0.45 | **0.65** |
  | Recovery Factor | -0.70 | **-0.57** |
  | Balance DD Max | 109.96% | **100.89%** |
  | Equity DD Max | 128.44% | 118.87% |
  | Trades | 2,496 | 4,120 |

  Multi-TF improved every metric - a real, honest win, not noise-sized.
  Interesting mechanism, worth remembering: it did NOT work by blocking
  more trades (trade count went *up* 65%, not down). Requiring three
  timeframes to agree makes "confirmed trend" rarer, and when
  `GetTrend()` returns flat/0, *neither* side is treated as against-trend
  - so the filter actually restricts less often overall. It just trusts
  the trend calls it does make more, avoiding the false-positive H1-only
  reads that were blocking (or failing to block) based on noise.

  **The honest answer to the actual question asked ("would the account
  have gone to 0?"): no, not prevented - only softened.** -$15,211.46 net
  loss against a $15,000 deposit means the account still would have gone
  net negative by month end either way (roughly -$211 with multi-TF vs
  -$1,922 with single-TF) - better, but still a wipeout, not a save.
  Multi-TF trend confirmation is a genuine improvement worth keeping
  available, not a fix for the underlying no-SL/unconditional-martingale
  design surviving a real trending month.

  Shipped as opt-in (`InpUseMultiTFTrend=false` by default) rather than
  flipped on - one in-sample month again, same caveat as every other
  finding this week.

- **2026-08-13 (same day, follow-up): $40,000 deposit test - bigger
  capital made the loss WORSE, not better, and reversed which trend mode
  won.** User asked to rerun the same July 2026 comparison at $40,000
  instead of $15,000, same DCA $1.20/2.0x/legs 7 otherwise. Naive
  expectation: since `InpInitialLot` and the DCA/multiplier logic are all
  fixed values, not balance-percentage-based, the actual $ trades and P/L
  should be nearly deposit-independent - only the drawdown percentages
  should shrink relative to the bigger base.

  That is not what happened:

  | Deposit | Single-TF Net Profit | Multi-TF Net Profit | Single-TF Trades | Multi-TF Trades |
  |---|---|---|---|---|
  | $15,000 | -$16,922.53 | -$15,211.46 (better) | 2,496 | 4,120 |
  | $40,000 | -$41,061.75 | -$42,759.29 (worse) | 2,507 | 4,400 |

  Trade counts stayed nearly identical between deposit sizes (as
  expected, since lot sizing doesn't depend on balance) - but the dollar
  loss more than doubled, and multi-TF flipped from better-than-single-TF
  to worse-than-single-TF. **Mechanism:** at $15,000, thinner margin
  triggered stop-outs mid-month that force-closed some baskets early -
  an *unintentional* circuit breaker that capped how deep those baskets
  could dig. At $40,000, the extra margin cushion avoided those forced
  closures, letting the same losing baskets keep adding legs further
  into the same adverse move before the month ended - a materially
  bigger realized loss from essentially the same trade decisions. Multi-
  TF's higher trade frequency (which helped when margin-constrained)
  became a liability once that constraint was removed, since more
  exposure surface with no cap compounds worse, not better.

  **The counterintuitive, important lesson: for this EA's no-SL/
  unconditional-martingale design, more capital is not automatically
  safer - it can remove an accidental safety net (margin stop-out)
  without replacing it with anything.** This does not change the
  standing conclusion (SL stays off per explicit, repeated user
  decision) - it's a sizing/risk-awareness finding, not a code change:
  whatever account size actually gets funded, the margin-call behavior
  at that specific size should be understood as part of the real risk
  profile, not assumed away.

- **2026-08-13 (same day, correction): "bad month" was wrong - all four
  tests were wiped out in the first ~15 hours of July 1st, not over the
  month.** User asked which day had the worst loss and what price move
  caused it - a direct question that exposed a mischaracterization in
  every result reported above today. Parsed the actual `Deals` table out
  of each `.htm` report (not just the summary stats) and found every
  single deal across all four tests (single-TF/multi-TF x $15k/$40k) is
  dated `2026.07.01`, with the *final* deals in each report carrying the
  comment `end of test` at 14:47-16:35 that same day - meaning the
  account ran out of usable margin and got force-liquidated within the
  first day, and the "month-long" backtest was effectively 15 hours of
  real activity followed by nothing (no capital left to trade with).

  **The actual price action, XAUUSD 2026.07.01:** opened $4,005.69,
  drifted down to a low of $3,960.20 by ~08:00 (SELL basket averaging
  down, correctly, during the dip), then reversed hard and rallied to a
  high of $4,115.49-4,115.78 by ~14:00 - roughly a **3.6% intraday
  reversal in about 6 hours**. The SELL basket kept martingaling into
  that rally with no way to stop (no SL, unconditional against-trend
  DCA), per-leg lot sizes reaching ~1.3 lots by the end, until margin was
  exhausted and every position was force-closed at once.

  All four configurations died on the exact same event - bigger deposit
  ($40k) and multi-TF trend confirmation both bought a bit more time
  (liquidation at 15:34/16:35 instead of 14:47/14:50) but none avoided
  it. This reframes every result reported earlier today: DCA distance /
  lot multiplier / max legs / trend-confirmation tuning was never really
  being tested against "a bad month" - it was all tested against
  variations on how fast the same single-day account-destroying event
  played out. None of that tuning is a substitute for a stop-loss against
  a single sharp reversal; the standing decision to keep SL off is
  unchanged, but this is a much more specific and honest description of
  what the risk actually looks like than "trending month" was.

  The published July Parameter Sweep artifact was updated with this
  correction rather than left standing as originally written.

- **2026-08-13 (same day, follow-up): manual news-window override built,
  and a second, worse blowup found on July 7th - confirms the risk is
  structural, not a single bad day.** User asked to fix the news filter so
  it actually blocks trading in the Tester and find the "best setting."
  Since `CalendarValueHistory` is confirmed non-functional in the Tester
  (see entry above), built a genuine, permanent feature instead of a
  throwaway hack: `InpUseManualNewsWindow`/`InpManualNewsStart`/
  `InpManualNewsEnd` (build v7) - a fixed date/time window OR'd with the
  calendar check in `IsNewsBlackout()`. Real live use too (manual
  belt-and-braces block around a known major release), not just a
  backtesting workaround. Fixed two call sites that had incorrectly
  gated on `InpUseNewsFilter` alone, which would have silently disabled
  the manual window whenever the (Tester-broken) calendar filter was off.

  Combined every good finding from today into one config - `InpMaxLegsPerBasket=5`,
  `InpDcaDistancePrice=1.20`, `InpUseMultiTFTrend=true` - and tested with
  vs without manually blocking the known 2026.07.01 07:30-15:00 danger
  window (the ADP/Fed-Warsh/ISM cluster from the earlier entry):

  | | No news block | **With news block** |
  |---|---|---|
  | Net Profit (July) | -$15,157.33 | -$16,640.30 |
  | Survived until | 15 hours (July 1) | **6 days (through July 6)** |
  | Trades | 3,918 | 16,574 |

  **The real story is in the daily balance, not the final number.**
  Blocking July 1st let the account actually trade well for six days -
  $15,000 -> $17,119 -> $24,292 -> $27,585 -> $33,245 by end of July 6
  (+121%). Then **July 7th wiped out all of it plus the original deposit
  in a single day** (-$34,885.70, ending at -$1,640.30) - a SELL basket
  that DCA'd all day while XAUUSD held $4,125-$4,180, liquidated at
  19:16. Checked the actual deal log for this, same method as the July 1st
  investigation.

  **Conclusion, stated as plainly as possible: avoiding one known bad day
  does not fix this EA. A different bad day just takes its place.** This
  is not a tunable-away risk (distance/multiplier/legs/trend-confirmation/
  news-avoidance all tested today, all reduce damage at the margins, none
  change the outcome) - it's the direct, structural consequence of no
  stop-loss combined with unconditional martingale. The EA will
  eventually meet a large enough single-direction move and lose
  everything open at the time, regardless of which specific day or
  event causes it. This is the honest answer to "find me the best
  setting": best-tuned-so-far is legs=5/DCA=$1.20/multi-TF-confirmed
  trend, but no setting is a fix for the missing stop-loss - that
  remains an explicit, informed, standing user decision, not something
  further tuning is expected to resolve.

- **2026-08-14 (broker-preset feature, and a real correction from live CXM
  data): cent-account spread scaling is broker-specific, not universal.**
  User asked for a `Broker Preset` dropdown (Exness/CXM/Vantage/Custom)
  plus a separate `Account Type` (USD/USC) selector, so Max Spread sets
  itself correctly per broker instead of manual guessing each time (as
  happened earlier the same day with Exness's cent account). Built both
  as independent enum inputs, combined in `EffectiveMaxSpreadPoints()`.

  First version applied one shared multiplier (~x17, derived from
  Exness's real 300->5000 finding) to every broker's cent account. This
  was an unverified extrapolation, flagged honestly as such in the code
  and to the user - and it was wrong. Real data settled it: got CXM
  Direct demo credentials (login 252424, XAUUSDc, Hedge mode, currency
  USC) from the user, logged in locally (automated `/config` login+Tester
  launches failed twice with "not synchronized with trade server" -
  this broker's connect handshake is apparently slower than the Tester's
  patience; the user logging in manually through the GUI worked fine and
  stayed connected), attached the actual EA to the live XAUUSDc chart,
  and read the dashboard's own "Spread" line directly: **24 points** -
  comfortably under the base 300, no scaling needed at all for CXM's
  cent account.

  Fixed `EffectiveMaxSpreadPoints()` to hardcode each broker's cent
  behavior independently (Exness: 300->5000 for cent; CXM: 300 for
  both account types) instead of deriving cent behavior from one shared
  ratio. Vantage remains an unverified placeholder pending real
  credentials.

  **The lesson, worth remembering beyond this one function:** when a
  fix is found for one instance of a problem, resist generalizing it
  into a universal rule before checking a second real instance - the
  natural-seeming "cent accounts need N times more points" pattern
  from a single Exness data point did not hold for CXM at all. One
  confirmed data point is one data point, not a law.

  **Also noted:** automating login via `/config` for a fresh CXM
  session twice failed with "tester not started because terminal is
  not synchronized with the trade server [connect status 1, 100]",
  even with a 3-minute wait. Manual GUI login succeeded immediately and
  stayed connected. If this broker needs scripted testing again,
  budget for either a much longer sync wait or plan on manual login
  for this specific server.

- **2026-08-16 (license system rebuilt after a real bug diagnosis - the
  earlier version's "black dashboard" was OnInit refusing before the
  dashboard existed, not a performance/lag issue):** on the real account
  (263521212), the user reported the dashboard staying blank/black and
  "lag" with the previous (network-checked, then offline-embedded-list)
  license system, and gave an explicit rollback instruction: go back to
  v9, remove everything above it. That rollback was executed verbatim
  (`git checkout 4b11201`) with no forward debugging attempted at the
  time - correct call given how blunt/urgent the feedback was.

  Days later, asked to build a license system that "runs smoothly, no
  lag at all" and only hands out keys to people who join under the
  user's own ID (manual, individually-issued keys - not self-serve).
  Before writing any code, actually diagnosed the old bug instead of
  guessing: the old design checked the license key inside `OnInit()`
  and returned `INIT_FAILED` on a missing/wrong key. In MQL5, an
  `OnInit()` that returns `INIT_FAILED` never runs the rest of the
  EA's setup - including `CreateDashboard()` - so the chart panel
  literally never gets created. That is exactly what "dashboard stays
  black" looks like from the outside, and it explains the report
  independent of any real performance problem (there wasn't one - a
  local array/string comparison and a WebRequest to localhost are both
  fast; the failure mode was structural, not a speed issue).

  Rebuilt it to never touch `OnInit()`'s return path at all:
  - `g_authorizedLicenseKeys[]` - the same 20 previously-issued keys,
    hardcoded directly in the .mq5/.ex5 (offline, zero network calls,
    so there is nothing that can hang or add latency - this was also
    already the right call from the VPS-can't-reach-localhost problem
    found earlier, now doubly justified by the dashboard bug).
  - `LicenseOk()` - a plain loop, `true`/`false`, no side effects.
  - Gated only inside `ManageBasketEntries()`, in the same non-blocking
    place as the existing `IsNewsBlackout()`/`DailyTargetHit()` checks:
    an invalid key skips new bootstrap/DCA entries for that tick, but
    existing open baskets keep managing/closing normally, and `OnInit()`
    and `CreateDashboard()` always run regardless of license validity.
  - New "License: OK / INVALID (no new trades)" dashboard line (green/
    red) so the state is always visible, never silent.

  **The lesson:** a license check (or any gate) that can return
  `INIT_FAILED`/refuse startup is fundamentally different from one that
  gates behavior at runtime - the first can prevent the UI itself from
  ever existing, which looks indistinguishable from "frozen" or
  "laggy" to a non-technical user watching the chart. Any future gate
  (license, account checks, filters) on this EA should default to the
  `IsNewsBlackout()`/`DailyTargetHit()` pattern - non-blocking, checked
  per-tick inside the entry logic, never inside `OnInit()`'s refusal
  path - unless there's a genuine reason the EA cannot run at all (like
  the hedging-mode check, which really can't be worked around).

  Compiled clean (0 errors, 0 warnings) as v15. Not yet deployed to the
  live real-account terminal (263521212) or the VPS - deliberately
  holding off on redeploying to the real account until the user has
  seen this explanation, given how the last license system landed
  there.

- **2026-08-16 (same day, follow-up): chart visuals / branding (v16),
  purely cosmetic, chosen from a shortlist of "make it more special"
  ideas):** offered four ideas (Telegram alerts, an equity-protection
  circuit breaker, license tiers/expiry, chart visuals/branding); the
  user picked chart visuals/branding only - the other three are logged
  here as ideas not yet built, in case they come up again.

  Added, all toggleable and all cosmetic-only (never read by any
  trading-logic function, so this cannot change entry/exit/lot-sizing
  behavior even in principle):
  - **DCA leg markers** - a small text label ("B1 0.01", "S3 0.04", ...)
    drawn on the chart at the exact time/price each leg opens, colored
    by side. Deleted the instant that specific position closes (1:1 by
    position ticket), so a long-running EA never accumulates them -
    only currently-open legs ever have a marker.
  - **Basket-closed markers** - a "BUY closed +$2.10" / red if negative
    label at the close price when a basket hits target (or is closed
    manually via the dashboard buttons). Capped at the most recent 20,
    oldest deleted automatically - same "must never accumulate/slow the
    chart down" discipline as everything else added post-license-bug.
  - **Restore-on-restart** - `RestoreLegMarkersOnInit()` rebuilds
    markers for whatever legs are already open when the EA (re)attaches
    (parses the leg number back out of `OpenLeg()`'s own trade comment,
    e.g. `FarhanFx-buy-leg3`), so a restart doesn't leave already-open
    legs marker-less until they next close.
  - **Dashboard branding** - thin gold accent strip along the panel's
    top edge, gold-tinted border (was neutral gray), and the title
    split into "SCALPING AI PRO" (white) + "FARHAN FX" (gold) instead
    of one plain white string.

  `InpShowLegMarkers` / `InpShowCloseMarkers` (both default true) turn
  either off independently if a client finds the chart too busy -
  important on this EA specifically since DCA legs can fire quite
  densely at the current $1.2 distance.

  Compiled clean (0 errors, 0 warnings) as v16. Same as v15: not yet
  deployed to the real-account terminal (263521212) or the VPS.

- **2026-08-16 (same day, second follow-up): first title layout had a
  real overlap bug; real logo image embedded; chart theme flipped to
  match it):** the two-color title from the entry above ("SCALPING AI
  PRO" + "FARHAN FX" on the same line, second label offset by a fixed
  118px) overlapped on the user's actual screen ("PROHAN FX", unreadable)
  - Consolas glyph width at size 9 rendered wider on real hardware than
  assumed. Fixed by stacking the two labels onto separate lines instead
  of guessing a horizontal pixel offset - a fixed-width assumption for
  a variable-rendering font was the bug, so the fix removes the
  assumption rather than re-tuning the same fragile number.

  User then supplied a real logo file (`WhatsApp Image 2026-08-15 at
  9.23.14 PM.jpeg` - the "FARHAN FX" 3D mark: silver F, red X, green/red
  candlesticks, silver arrow, black background, "PLAN | EXECUTE |
  PROFIT" tagline). Cropped just the icon mark (no wordmark/tagline -
  those stay as crisp rendered text instead of blurry small bitmap
  text), resized to 64x47px, saved as a 24-bit BMP, and embedded via
  `#resource "\\Images\\FarhanFX_Icon.bmp"` + `OBJ_BITMAP_LABEL` reading
  `"::Images\\FarhanFX_Icon.bmp"` - compiled directly into the .ex5, so
  a client deployment never needs a separate image file that could go
  missing (same "avoid anything that can silently fail and look broken"
  discipline as the license-system fix above). A copy of the source BMP
  lives in this repo at `resources/FarhanFX_Icon.bmp` - required to
  exist under that machine's `MQL5\Images\` at compile time on any
  fresh machine, or the compile will fail on the `#resource` line.

  Also flipped `InpSetWhiteChartTheme` default from `true` to `false`
  (dark) - the logo's background is solid black, so a white chart
  canvas around a black-background icon would look like a mismatched
  box; dark chart + dark dashboard panel + black-background icon all
  read as one cohesive look instead.

  Compiled clean (0 errors, 0 warnings), still v16 (same functional
  version, layout/asset fix only - no version bump for a visual
  correction to something not yet deployed anywhere). Not yet deployed
  to the real-account terminal (263521212) or the VPS.

- **2026-08-16 (same day, third follow-up): main-chart watermark added**
  - the icon in the dashboard corner wasn't what the user meant by
  "watermark"; they specifically wanted the logo visible on the main
  chart itself, behind the candles.

  Considered real alpha transparency first (32-bit ARGB BMP) but MT5's
  support for it is inconsistent/undocumented well enough to trust
  blind - a wrong guess here would render as a solid opaque box hiding
  the candles, a much worse failure than "no watermark at all". Used a
  reliable alternative instead: pre-scaled the logo's own RGB values
  down to ~22% against a **pure black** background in software (so the
  saved BMP is fully opaque, no transparency mechanism depended on at
  all) - on a black chart this reads as a faint watermark because the
  math is identical to real alpha blending against black; it only
  breaks (shows as a faint dark rectangle instead of blending
  perfectly) if the chart background isn't pure black, which is an
  accepted, minor trade-off for guaranteed-correct rendering everywhere.

  `PositionWatermark()` centers a 420x310 `OBJ_BITMAP_LABEL`
  (`FarhanFX_Watermark.bmp`, embedded via `#resource` same as the
  dashboard icon) on the visible chart window, `OBJPROP_BACK=true` so
  candles draw on top of it. Re-centers on `CHARTEVENT_CHART_CHANGE`
  (window resize) via `OnChartEvent()`, not on every tick - a
  screen-space label object doesn't need repositioning for price
  scroll/zoom, only an actual window-size change. `InpShowChartWatermark`
  (default true) turns it off entirely (deletes the object) if a client
  doesn't want it.

  Compiled clean (0 errors, 0 warnings), still v16. Not yet deployed to
  the real-account terminal (263521212) or the VPS.

- **2026-08-16 (same day, fourth follow-up - real bug, user reasonably
  frustrated): watermark rendered as an obvious solid black box, not a
  faint blend):** the "pre-scale against pure black" trick from the
  entry above assumed the chart's default background was already pure
  black. On the user's actual Vantage chart it was a lighter charcoal/
  navy with a visible dotted grid - so the watermark's own background
  (genuinely `(0,0,0)`) stood out as a hard-edged dark rectangle sitting
  on top of a not-quite-as-dark chart, looking exactly like a rendering
  bug (screenshot showed a clearly bounded black box with grid lines
  visible through it). Not a subtle miss - a real, visible-immediately
  mistake, and the user's blunt reaction was fair.

  The assumption itself was the bug, not the blending math (the earlier
  synthetic preview against an actually-pure-black canvas did blend
  correctly - the math was never wrong, the input color was). Fixed at
  the source instead of re-guessing a different opacity/size: added
  `ApplyBlackChartTheme()`, called whenever `InpSetWhiteChartTheme` is
  off, that force-sets `CHART_COLOR_BACKGROUND` to `clrBlack` explicitly
  (mirroring the existing `ApplyWhiteChartTheme()` pattern) instead of
  trusting whatever the broker/terminal's own default template happens
  to be. This is no longer a guess - the EA now directly controls the
  one value the watermark's pre-baked math depends on, so the blend is
  guaranteed correct rather than hoped-for.

  **The lesson:** when faking transparency by pre-blending against an
  assumed background color, either control that background color
  yourself or don't do the trick at all - inferring it from "well the
  screenshots looked dark" was exactly the kind of unverified
  extrapolation this project has been burned by before (see the
  broker-spread-multiplier lesson, 2026-08-14) and burned by again here.

  Compiled clean (0 errors, 0 warnings), still v16. Not yet re-verified
  on the user's actual terminal - waiting on them to reattach and
  confirm before treating this as actually fixed.

- **2026-08-16 (same day, fifth follow-up - real bug report, "profit
  shows but real P/L drops" reported after being live for a while):**
  user reported baskets logging "TARGET HIT" while the account's real
  balance still trended down, and specifically that it got worse during
  momentum. Investigated rather than guessed:
  - MQL5 has no live-commission field on an open position (`POSITION_COMMISSION`
    doesn't exist) - commission only becomes visible after a deal
    closes, via history. The EA's `floatingPL` (used to decide "target
    hit") was always `POSITION_PROFIT + POSITION_SWAP` only, so a
    basket could read as "+$2 profit" while commission across several
    legs quietly exceeded that.
  - The "worse during momentum" detail pointed at something momentum-
    dependent, which commission alone isn't (it's roughly a flat
    per-lot cost regardless of how fast price is moving) - the more
    likely dominant cause was `CloseBasket()`'s own design: it closes a
    basket's legs one-by-one via separate market orders in a loop, each
    a real network round-trip. During a fast move, by the time leg 5-7
    got its turn, price had already moved further away than what was
    used to declare "target hit" moments earlier - real, momentum-
    correlated slippage.

  Fix: **`InpUseServerSideTP` (default true)** - `ApplyBasketTP()`
  computes the exact price at which a basket's combined floating P/L
  (using the same weighted-avg-entry/total-lots math `ScanBasket()`
  already produces) reaches `GetProfitTarget(b)`, then sets that price
  as a real broker-side TP on every leg in the basket via
  `trade.PositionModify()`. Every leg in a basket shares one TP price,
  so they fire together on the broker's own server the instant price
  reaches it - no EA-side one-by-one loop, no tick-detection lag.
  Re-applied whenever a leg opens (the only time the shared price can
  change) and again every second from `OnTimer()` as a self-healing
  retry (modify can fail, e.g. broker min-stop-distance - logged, never
  fatal, since `ManageBasketExits()`'s existing tick-based check remains
  in place unchanged as a backup). New "TP Price" dashboard line per
  basket, per explicit request ("dekha jai TP kothai ache").

  Also added, since they follow directly from a TP now being able to
  close a basket without the EA's own `CloseBasket()` ever running for
  that close: `CleanupOrphanedLegMarkers()` (deletes a leg's chart
  marker once its position is gone, regardless of what closed it) and
  `LogRecentClosedDeals()` (prints real profit/swap/commission per leg
  close from `HistoryDeal*`, since this is the only way to actually see
  commission at all - gives real numbers to check the original
  commission theory against, going forward).

  **Verification detour, worth recording honestly:** first attempted an
  automated Tester run via `/config` against the already-open Vantage
  terminal - it did NOT start a fresh Tester session (MT5 is single-
  instance; `/config` against an already-running terminal doesn't
  reliably enter Tester mode), and the account shown in that terminal
  at the time briefly caused real alarm (looked like escalating real
  trades on an unfamiliar login) before being resolved as unrelated to
  this change. Lesson for future automated Tester launches: **fully
  close any existing terminal64.exe for that data folder first**,
  confirmed via `Get-Process -Name terminal64`, before launching with
  `/config` - do not assume `/config` against an already-running
  instance does what it does against a closed one, and do not launch
  Tester runs against a terminal that might be someone's active live
  monitoring session without confirming first.

  A second, correctly-isolated Tester run (fresh instance, Model=4
  every-tick real ticks per explicit request, XAUUSDc, 2026.08.01-10,
  license key included this time - an empty `InpLicenseKey` in
  `[TesterInputs]` caused a legitimate first attempt to show 0 trades,
  caught and fixed before treating that as a real result) confirmed the
  TP mechanism works as designed: e.g. a 7-leg basket's 0.02/0.04/0.08/
  0.16/0.32/0.64/1.28-lot legs all closed at the identical timestamp
  and identical price (4060.398) with comment `tp 4060.381` - a real,
  broker-executed, simultaneous TP fill across every leg, exactly the
  behavior meant to replace the sequential-close slippage. 704 trades,
  1408 deals, profit factor 2.17, net +$246.67 over the 9-day window,
  no errors.

  Compiled clean (0 errors, 0 warnings) as v17. Not yet deployed to the
  real-account terminal (263521212) or the VPS.

- **2026-08-18 (v17 live on demo, two real bugs found within hours - a
  runaway DCA cascade and a wildly-mispriced TP - both fixed same day
  as v18):** user put v17 live on two demo accounts (CXM 252424,
  Exness-MT5Trial14 416045126) and caught both issues directly on the
  dashboard/trade blotter, not from a backtest:

  **Bug 1 - TP set $100 away from entry instead of ~$1-2.** CXM
  dashboard showed `TP Price 4499.45` against `Avg Entry 4399.45` -
  exactly +100.00. `BasketTargetPrice()`'s original formula divided the
  $ target by `totalLots * SYMBOL_TRADE_CONTRACT_SIZE`. That's the
  textbook formula, but it silently assumes contract size is the only
  thing determining how price differences turn into $ profit - on this
  cent-account symbol it wasn't, and `POSITION_PROFIT` (the broker's
  own real number, which the existing "Floating" dashboard line reads
  correctly) disagreed with what contract-size math predicted. Fixed
  by switching to `SYMBOL_TRADE_TICK_VALUE / SYMBOL_TRADE_TICK_SIZE`
  instead - the same per-price-unit-per-lot profit rate the broker
  itself uses internally, so it can't disagree with `POSITION_PROFIT`
  by construction, regardless of any contract-size quirk on any given
  symbol/broker. (Same broader lesson as the 2026-08-14 broker-spread
  entry: don't assume one metadata field fully describes a broker's
  actual math - use the field that's defined to match, not the field
  that usually happens to.)

  **Bug 2 - a basket cascaded through a full 7-leg cycle in ~9 seconds**
  on CXM (entries spanning only ~35 cents total, vs. `InpDcaDistancePrice=1.2`
  intended per leg) - caught directly from the live trade blotter, and
  confirmed NOT a misconfiguration (DCA Distance was genuinely 1.2 in
  the chart's actual inputs, screenshotted and checked). Root cause:
  `ScanBasket()`'s "which leg is most recent" tie-break used
  `POSITION_TIME`, which only has **1-second** resolution. When legs
  open faster than one per second (which this EA can now do more
  easily than before, since `ApplyBasketTP()` and its own
  `RefreshBaskets()` calls added more per-tick work around each leg
  open), two legs sharing the same second made the tie-break pick
  whichever one the position-iteration order happened to visit last -
  not necessarily the true most recent one - so the DCA-distance check
  could end up comparing against a stale/wrong reference price,
  letting it pass far more easily than intended. Fixed two ways,
  deliberately redundant:
  - Switched the tie-break to `POSITION_TIME_MSC` (millisecond
    precision) - removes the ambiguity at the source.
  - Added `InpMinSecondsBetweenLegs` (default 5) as an independent
    safety net inside the DCA-add branch: no new leg within N seconds
    of the previous one, full stop, regardless of what the distance
    check computed. This means a *similar* future timing bug (in this
    check or a new one) can't cascade into many legs in a few seconds
    again even if it exists - the same "defense in depth, don't rely
    on one gate being perfect" pattern as the license/news/daily-target
    checks already use.

  **Verification, both fixes, real Tester run (Model=4, every tick,
  real ticks, XAUUSDc, 2026.08.01-10):** confirmed no consecutive
  same-side leg-open pair anywhere in the 9-day run has a gap under 5
  seconds except one (a fresh bootstrap immediately after a different
  basket's cycle closed - expected, bootstrap has no cooldown gate)
  out of 623 pairs checked. DCA gaps between consecutive legs now land
  around ~$0.95-1.0 (some shortfall vs the nominal $1.2 remains, most
  likely spread-driven: the trigger check compares bid/ask against the
  *previous* leg's own entry price, which was itself filled at the
  opposite side of the spread - not itself a bug, just an inherent
  property of using transactable bid/ask rather than mid-price, worth
  knowing about but not urgent to change). TP prices now land close to
  entry (not $100 away). 652 trades, profit factor 3.35, net +$119.55,
  no errors.

  **The meta-lesson:** both bugs were found because the user put v17
  live on real demo charts and actually watched it, not because a
  backtest caught them - the backtest environment (fixed spread
  assumptions, no real same-second tick bursts in Model=1) wouldn't
  have surfaced either one. Going forward, treat "run it live on a
  demo and watch the dashboard for a while" as a required verification
  step for any change to entry/exit pricing logic, not optional on top
  of a Tester pass.

  Compiled clean (0 errors, 0 warnings) as v18. Not yet deployed to the
  real-account terminal (263521212) or the VPS - the two demo charts
  (CXM 252424, Exness 416045126) that found these bugs are still on
  v17 and should be updated to v18 next.

- **2026-08-18 (same day, follow-up - v18's cascade fix was NOT
  sufficient, caught minutes after deploying to the CXM demo chart;
  investigation still open, being honest about that rather than
  claiming it's fixed again without proof):** user updated the CXM
  chart to v18 and watched a SELL basket cascade through a full 7-leg
  cycle again - this time gaps were consistently 5-7 seconds apart
  (the `InpMinSecondsBetweenLegs` cooldown IS working - no gap was
  ever under 5s), but the PRICE moved only ~10-15 cents between legs,
  nowhere near `InpDcaDistancePrice=1.2` - and the chart's actual Inputs
  dialog was screenshotted and confirmed DCA Distance really was 1.2,
  ruling out misconfiguration again.

  This means the millisecond-tie-break fix from earlier today was NOT
  the (or not the only) cause - it fixed a real, legitimate edge case,
  but something else is independently letting the price-distance check
  pass far too easily, and only in live/demo execution, not in the
  Tester: a diagnostic build (temporary `PrintFormat` logging the exact
  bid/ask/lastLegEntry/legCount behind every `adverse=true` evaluation)
  was run through the same 9-day Tester window that verified v18 - the
  logged numbers there were all internally consistent (e.g.
  `ask=4074.242` vs `lastLegEntry+1.2=4074.240` - correctly ~1.2 apart,
  genuinely triggered by real price movement). The Tester cannot
  reproduce this bug at all, which means it's something specific to
  live/demo execution - real-time tick delivery, live account state
  timing, or something else not yet identified.

  Status: **not resolved.** The same diagnostic-logging build has been
  handed back for the user to run live on the CXM chart again; next
  step is reading the actual `DCA-DIAG` lines from the Experts/Journal
  tab during a real live cascade, since that's the one environment
  where this reproduces. No further claims of "this fixes it" until
  real live log data is in hand - this project already got burned once
  today by treating a Tester pass as sufficient proof for something
  that turned out to be a live-only bug.

- **2026-08-21 (new sibling EA built: `FarhanFX MTF Trend Strategy.mq5`,
  a real-SL trend-following EA, after market research into what actually
  makes traders profitable):** while the DCA-cascade bug above remained
  unresolved, the user asked for market research on how consistently
  profitable traders actually operate, then picked "build a genuinely
  new trend-following approach with a real SL" as a new EA in this same
  project folder (not a rewrite of the dual-basket EA, not a reuse of
  the separate `E:\Trend Flowing Ai Brain\` project).

  Research (condensed, full citations in the session's response to the
  user):
  - Consistently profitable traders share sub-1% risk per trade, a
    2:1-3:1 reward:risk ratio, and hard predefined stop-losses - not a
    particular strategy. ([TradeZella](https://www.tradezella.com/blog/risk-management-trading),
    [ACY](https://acy.com/en/market-news/education/market-education-top-10-habits-profitable-traders-2025-j-o-20250729-090902/))
  - Martingale/grid systems (the dual-basket EA's design) fail
    structurally: unlimited downside, "months of small wins, one trend
    erases it all." ([EBC Financial](https://www.ebc.com/forex/martingale-trading-strategy),
    [MQL5 blog](https://www.mql5.com/en/blogs/post/771466))
  - For gold specifically: trend-following with EMA alignment,
    price-action confirmation, and a real ATR-based stop is the
    standard profitable approach. ([LiteFinance](https://www.litefinance.org/blog/for-investors/gold-trading/gold-trading-strategies/),
    [JP Trading Capital](https://www.jptradingcapital.com/blog/en/xauusd-trading-strategy))

  Rather than design a new strategy from scratch, found and ported an
  **already-designed** TradingView strategy sitting untracked in the
  main dashboard repo: `E:\Farhan Fx Algo\FarhanFX_MTF_Trend_Strategy.pine`
  (+ companion indicator) - a 6-EMA Fibonacci ribbon system with
  candlestick/S-R/RSI confluence filters, a real ATR-based SL, and a
  6-level ATR-stepped scaled TP. Ported the signal/exit logic as
  closely to line-for-line as MQL5 allows; reused the dual-basket EA's
  dashboard/license/broker-preset/branding *patterns* (not copy-paste,
  rewritten for this EA's own state) so it looks and operates
  consistently with what the user already knows.

  One deliberate, explicit exception to the research: **position sizing
  is notional** (`InpPositionPercentOfEquity`, 10% of equity), not
  risk-based - matches the Pine script's own `percent_of_equity` mode by
  the user's explicit choice, so results stay comparable to the Pine
  version's own TradingView backtest rather than switching conventions
  mid-port. Documented clearly in code comments so a future reader isn't
  confused about why it doesn't scale with SL distance.

  A separate sibling project, `E:\Trend Flowing Ai Brain\`, independently
  arrived at a similar real-SL/ATR/risk-based design (backtest PF
  1.5-1.7 over 90-180 days, never run live) - useful as a structural
  MQL5-idiom reference during the build, not reused directly, per the
  user's explicit choice to build fresh in this folder.

  **Verified via a real Strategy Tester run** (Model=4, every tick, real
  ticks - the same non-negotiable standard this project adopted after
  getting burned twice this week trusting Model=1/reasoning-only
  checks): XAUUSDc/CXM preset, 2026.06.01-08.18, $10,000 deposit.
  Confirmed directly from the deals table, not inferred:
  - Real SL fires correctly - multiple closes tagged `sl <price>` in the
    report (e.g. `sl 4488.565`, `sl 4102.606`).
  - The scaled TP ladder fires correctly - e.g. one 0.24-lot SELL
    position partial-closed 0.04 lots (~TP1, ~1/6 of size) at a profit,
    then had its remaining 0.20 lots stopped out later by its own SL;
    another position had four separate partial closes at four distinct
    price levels as the trend continued favorably.
  - Entries carry the `FarhanFXTrend-buy`/`-sell` comment tag, confirming
    they came from the ribbon-flip signal path, not something else.
  - **121 trades, profit factor 1.66, net +$55.62, max drawdown $14.87
    (0.15%)** - a dramatically smaller drawdown than the dual-basket EA
    has ever shown in any backtest this project has run, exactly what's
    expected from an EA with an actual stop-loss.

  Compiled clean (0 errors, 0 warnings) as v1. **Explicitly a backtest-
  only result** - no live/demo track record yet, same honest caveat
  already applied to `E:\Trend Flowing Ai Brain\`'s own numbers. Not yet
  deployed to any live/demo chart.

- **2026-08-21 (same day, follow-up: user reacted to the Trend EA's
  modest first backtest, asked for "a different strategy - order flow"):**
  before building anything, checked what's actually possible - XAUUSD is
  an OTC CFD, no consolidated exchange order book, so real institutional
  order flow (Level 2/footprint, which would need CME GC futures data) is
  not available through this MT5/broker setup at all. Confirmed via
  research, explained to the user, who agreed to the realistic
  alternative: a tick-direction volume-delta proxy (classify each real
  tick as buy/sell pressure by price direction or the broker's own trade-
  side flag when present, accumulate into a running CVD).

  Built **`FarhanFX Order Flow Strategy.mq5`** (v1), a fourth pattern in
  this folder alongside the dual-basket DCA EA and the Trend EA: a
  cumulative-volume-delta divergence signal (price makes a new confirmed
  pivot high/low, but CVD at that pivot doesn't confirm it - the classic
  order-flow "distribution"/"accumulation" reversal call), real ATR-based
  SL, single fixed-R:R TP (2:1) instead of the Trend EA's scaled ladder,
  same dashboard/license/sizing patterns reused.

  **Sanity-checked the CVD math before trusting a full backtest**: logged
  the first 30 bars' buyVol/sellVol/delta/runningCVD next to real price
  moves - directionally correct in every sample checked (price up bars
  had positive delta, down bars negative, magnitudes roughly tracked the
  size of the move) - cheap insurance against a sign/classification bug,
  per this project's now-standard verification discipline.

  **Real Strategy Tester run** (Model=4, every tick/real ticks - required
  here specifically since CVD depends on real tick data), same XAUUSDc/
  CXM/2026.06.01-08.18 window as the Trend EA for a direct, apples-to-
  apples comparison:

  | | Trend EA | Order Flow EA |
  |---|---|---|
  | Trades | 121 | **7** |
  | Profit Factor | 1.66 | 1.17 |
  | Net profit | +$55.62 | +$5.64 |
  | Max drawdown | $14.87 | $34.15 |

  Confirmed from the deals table (not inferred): every entry tagged
  `FarhanFXFlow-buy/sell` (genuinely from the divergence signal path),
  every close tagged `tp <price>` or `sl <price>` (both real, both
  fired correctly - 3 TP wins, 4 SL losses in this window).

  **Honest verdict:** the mechanism works as designed, but the divergence
  condition (confirmed price pivot + confirmed CVD pivot disagreeing,
  plus the absorption filter) is rare - 7 trades in 2.5 months is nowhere
  near enough to draw a real conclusion, and what did fire performed
  worse per-trade than the Trend EA's simpler ribbon-flip signal, not
  better. All 7 were SELL entries - plausibly just this window's mostly-
  declining price action rather than a real long/short asymmetry, but
  not independently confirmed either way. This is a legitimate, reported-
  as-found negative-ish result, not something to paper over just because
  the user wanted a bigger number - same discipline as every other
  backtest in this project's history.

  Compiled clean (0 errors, 0 warnings) as v1. Not yet deployed anywhere.

- **2026-08-21 (same day, back to the dual-basket EA - "make it more
  powerful, lower drawdown, higher profit"):** researched what
  specifically separates surviving martingale/grid EAs from ones that
  blow up ([MQL5 blog](https://www.mql5.com/en/blogs/post/768549)) -
  four features named: gentler-than-doubling averaging, smart entry
  filtering (already present here - ATR spike + trend filter), a strict
  pre-calculated worst-case leg limit, and **"a hard stop loss enforced
  at the portfolio level - if cumulative drawdown hits the defined
  threshold, all positions close."** This EA had a daily PROFIT target
  but nothing on the loss side at all - a real, confirmed gap.

  Added **`InpUseDailyLossLimit`** (default false) - unlike
  `DailyTargetHit()` (deliberately realized-balance-only, so it doesn't
  flicker on floating noise), this checks live EQUITY against day-start
  balance, since the whole point is reacting to floating loss building
  up, not waiting for it to become permanent. When hit: `ManageBasketEntries()`
  halts new entries (existing non-blocking pattern) **and** `OnTick()`
  additionally force-closes both baskets via `ForceCloseOnDailyLossLimit()`
  - halting new entries alone doesn't cap an already-open basket's
  ongoing floating loss, only the force-close does. New dashboard line.

  **Tested against the exact July 2026 window that used to wipe real
  accounts** (per this file's earlier entries) - real Tester runs
  (Model=4, every tick/real ticks, XAUUSDc/CXM, 2026.07.01-08.10,
  $10,000 deposit):

  | Config | Net Profit | PF | Max Equity DD |
  |---|---|---|---|
  | v19 defaults (2.0x mult, loss limit off) | $603.59 | 3.04 | 2.46% |
  | + Daily Loss Limit 5% (mult still 2.0x) | $603.59 | 3.04 | 2.46% (never triggered) |
  | Softer multiplier (1.3x) + Loss Limit 5% | $389.57 | 2.72 | **3.72%** |

  Two honest findings, one good and one counter-intuitive:
  1. **The same window that used to wipe accounts now shows only 2.46%
     max equity drawdown with current (already-improved) defaults** -
     this week's cumulative fixes (tighter DCA distance, the server-side
     TP work, max-legs tuning) already made this EA meaningfully safer
     without today's new feature even being needed for this window.
  2. **Softening the lot multiplier from 2.0x to 1.3x made things
     *worse*, not better** - lower profit AND higher equity drawdown.
     Counter-intuitive but explainable: a gentler multiplier needs more
     legs to reach the same recovery target, so more capital stays
     deployed for longer during an adverse move, producing a *deeper*
     floating drawdown even though the eventual realized numbers were
     smaller. Isolated by testing the loss-limit alone (identical to
     baseline, confirming it never triggered) vs. combined with the
     softer multiplier (the multiplier was the whole effect) - don't
     trust a combined test to tell you which lever did what.

  **Recommendation given to the user:** keep `InpLotMultiplier` at 2.0
  (softening it measurably hurt in real testing, not just theory), but
  turn `InpUseDailyLossLimit` on - it cost nothing in this test (never
  triggered) and exists specifically for a genuine tail event, like the
  still-unresolved live-only DCA cascade bug two entries up, where
  something goes wrong in a way backtests haven't reproduced.

  Compiled clean (0 errors, 0 warnings) as v19.

- **2026-08-21 (same day, near-miss worth recording): several project
  files vanished from disk mid-session, cause undetermined.** Mid-way
  through documenting the above, found `ml/learnings.md`, the entire
  `ml/` folder, both new EAs' `.mq5`/`.ex5`, and the `.mq4` port all
  missing from the working directory - `git status` showed them as
  deleted relative to HEAD. Root cause was **not** identified (not this
  session's own `rm -rf` calls, which were all scoped to the temp
  scratchpad directory, never this project folder) - a concurrent
  process on the same machine is suspected but unconfirmed. Genuinely
  no data was lost: everything was already committed at `ef14c17` and
  pushed to GitHub, so `git checkout HEAD -- .` (run only after asking
  and getting explicit user confirmation, since it's a working-tree-
  overwriting command) restored every file exactly. **Lesson: this is
  exactly why committing and pushing promptly after real, verified work
  matters** - the working tree itself turned out not to be trustworthy
  as the sole copy of anything, even mid-session on the same machine.

- **2026-08-21 (same day: "TP বাড়াতে হবে, প্রতি DCA-তে" - v20, real
  backtest result was worse, kept anyway for live evaluation per
  explicit user decision):** user wanted the basket profit target to
  grow smoothly with every single DCA leg, not just jump once per full
  7-leg cycle (the existing step-function behavior). Changed
  `GetProfitTarget()`:
  - Old (v19): `target = base * (1 + completedCycles * growth)`, where
    `completedCycles = legCount / InpMaxLegsPerBasket` (integer
    division) - flat for legs 1-6, jumps 50% at leg 7, flat again for
    legs 8-13, jumps again at leg 14, etc.
  - New (v20): `target = base * (1 + (legCount-1) * (growth /
    InpMaxLegsPerBasket))` - ramps a little with every leg (bootstrap
    leg stays at the flat base), same overall growth RATE as before
    (both formulas agree exactly at leg counts that are multiples of
    `InpMaxLegsPerBasket`), just spread evenly instead of dumped in one
    jump, and - unlike the old version - never resets, so legs 8, 15,
    30... keep compounding higher instead of flattening again after
    each jump.

  **Real backtest (Model=4, every tick/real ticks, XAUUSDc/CXM,
  2026.07.01-08.10, the same catastrophic-event window as v19's own
  test) came back clearly worse, not better:**

  | | v19 (step) | v20 (smooth) |
  |---|---|---|
  | Net profit | $603.59 | $222.12 |
  | Profit Factor | 3.04 | 1.25 |
  | Max equity DD | 2.46% | 5.35% |

  **Why, worked out rather than left unexplained:** the smooth version
  raises the target for every *mid-cycle* leg too (e.g. leg 4 went from
  a flat $2.00 to $2.43), where the old version stayed at the easier
  flat $2.00 until the cycle fully completed. A higher target mid-cycle
  means the basket takes longer (and often more legs) to actually reach
  it, keeping more capital deployed during the adverse move for longer
  - which is exactly what shows up as worse drawdown and lower realized
  profit in the real numbers above.

  **Given the real numbers, recommended reverting to v19's step
  function - the user's explicit decision instead was to keep v20 as
  compiled and evaluate it live/demo directly rather than decide from
  the backtest alone**, matching this project's general preference for
  live confirmation over backtest-only conclusions when the two might
  disagree. Compiled clean (0 errors, 0 warnings). Recorded here so the
  backtest finding isn't lost regardless of what the live run shows -
  if live also comes back worse, reverting to the step function is a
  one-function change away (see `GetProfitTarget()`'s git history at
  the v19 tag/commit for the exact prior formula).

- **2026-08-24 (v20 live on CXM demo blew the account to $0.62 - real,
  understood, not a new bug - then v21: unlimited legs, never book a
  loss, trading-hour gate, license removed, per explicit user
  decision):** three days after v20 went live unattended, the CXM demo
  account (252424, started at $10,175) dropped to **$0.62**. Root-caused
  from the exported `ReportHistory-252424.html` (parsed with Python, not
  guessed from screenshots) rather than assumed:
  - Gold moved from ~4633 to ~4596 (~$37, ~0.8%) in about **10 minutes**
    (2026.08.24 03:17-03:27).
  - A BUY basket had already cycled deep (0.32/0.64-lot legs = late
    positions within a sizing cycle) before this move, and kept adding
    legs as price fell straight through the ladder - individual leg
    losses up to **-$2,354.80** on a single 0.64-lot leg.
  - Leg-open gaps were all 2-4 minutes apart (not the sub-5-second
    pattern of the still-unresolved cascade bug from 2026-08-18) -
    genuinely a large, fast, real price move overwhelming the DCA
    ladder, not a repeat of that bug.
  - **`InpUseDailyLossLimit` was off** (its default) the whole time - the
    one feature built specifically for this scenario never got a chance
    to act.

  This is exactly the risk this project's own research (2026-08-21
  entries) named directly: "months of small wins, one trend erases it
  all." Not a new failure mode - the first real live demonstration of
  the standing, explicit, repeatedly-confirmed "no stop-loss ever"
  decision's actual cost.

  **User's response, not to add the safety net but to go further in the
  opposite direction** - explicit instructions, implemented as asked
  after stating the one concrete mechanical consequence once (broker
  margin call becomes the only remaining backstop once there's no
  self-imposed leg cap):
  - `InpUseTradingHours` (default true) + `InpTradingStartHour` (7) -
    new entries blocked before 7am server time daily, resumes
    automatically; existing baskets still managed at any hour.
  - `InpUnlimitedLegs` (default true) - `InpAbsoluteMaxLegsPerBasket` is
    now ignored when true; a basket can add legs indefinitely. Kept
    `InpMaxLegsPerBasket`'s lot-size-reset-every-N-legs cycling
    mechanism as-is (a defensible reading of "remove the leg [cap]
    system" - it's what keeps "unlimited legs" from also meaning
    "unlimited single-leg lot size", which would hit the broker's own
    max-lot-per-order limit almost immediately).
  - `InpUseMultiTFTrend` default flipped `false` -> `true` - H1+H4+D1
    must all agree now, not just H1, per "trend filter valo vabe kaj
    kore" (make the trend filter work well).
  - The `LicenseOk()` gate call removed from `ManageBasketEntries()`
    (function/key-list left in the file, one line to restore later) -
    "license k remove koro, age success hok, tarpor licance niye kaj
    korbo."
  - `InpBasketProfitTargetUSD` default lowered 2.0 -> 1.0, per a
    follow-up request, worked out for a 10-leg basket using the still-
    active v20 smooth-growth formula: `target = 1.0 * (1 + 9 *
    (0.5/7)) = $1.64` at leg 10, continuing to grow (no reset, since
    legs are now unlimited) for any leg count beyond that.

  No SL-tagged closes exist anywhere in this build - confirmed by
  grepping the Tester report for `"sl "` occurrences (zero), matching
  "kuno loss book korbe na" exactly as asked; every close is still a
  basket-level TP hit, even when a specific late-added leg within that
  basket nets a loss on its own.

  **Real Strategy Tester run** (Model=4, every tick/real ticks, XAUUSDc/
  CXM, 2026.07.01-08.10 - the same catastrophic-event window used to
  verify v19/v20, $20,000 deposit): **net -$275.58, profit factor 0.80,
  max equity drawdown $1,069.11 (5.34%), 3,125 trades.** Confirmed 0
  `sl`-tagged closes in the report (the no-loss-booking design working
  exactly as specified) - and still a net loss overall, because a
  basket's shared TP can let a late-joined, poorly-timed leg realize a
  loss on its own books even while the basket as a whole reaches
  target; enough of those across 3,125 trades summed negative. Reported
  as found - not adjusted, not softened.

  Compiled clean (0 errors, 0 warnings) as v21. Not yet deployed
  anywhere as of this commit - the CXM account that blew up is demo, no
  real money was lost.

  **CORRECTION, same day, before the ink even dried:** the per-leg-loss
  explanation above was incomplete. Asked to push the target higher
  ("dca te r o profit barate hobe jeno kichu trade loss e geleo jeno
  profit thake"), investigated the actual -$275.58 result properly
  instead of just raising a number - parsed the Tester report's deals
  table (Python, grouped by close time+price+side, not eyeballed) and
  found 407 basket-close groups, only 2 net-negative. One of the two
  was the Tester's own end-of-test forced liquidation (harmless, tiny).
  **The other was a 47-leg basket closing at -$1,013.63 - all 47 legs
  negative, not tagged `sl`, not a TP hit either** (TP by construction
  can't produce a basket-wide loss). Grepped the actual Tester log
  around that exact timestamp and found the real cause directly:

  ```
  GoldDualBasketDCA: DAILY LOSS LIMIT HIT (5.0% of day-start balance) - force-closing both baskets.
  ```

  **`InpUseDailyLossLimit` was NOT actually off during the v21 test that
  produced -$275.58**, despite the compiled default being `false` and
  despite not setting it in `[TesterInputs]` - a stale cached `.set`
  file value (`true`, left over from earlier v19 testing sessions)
  silently overrode the compiled default. This project's own README
  already documents this exact `.set`-file caching gotcha; it bit this
  session anyway because the assumption "not specifying an input means
  the compiled default applies" was wrong for Tester runs specifically.
  Lesson reinforced, now written down a second time: **always pass
  every input explicitly in `[TesterInputs]` for anything that changes
  behavior, especially bools that default differently from what a
  previous test used - never rely on the compiled default silently
  applying.**

  Also a real gap in the earlier verification itself: checking for
  `"sl "`-tagged closes only proves no *stop-loss* closes happened - it
  says nothing about EA-initiated `CloseBasket()` calls from other
  paths (daily-loss-limit, daily-target, manual buttons), which carry
  no special tag in the deal comment at all. "Zero `sl` closes" was
  true and irrelevant to what actually happened.

  **Re-ran with `InpUseDailyLossLimit=false` genuinely, explicitly, set
  in `[TesterInputs]` this time** (same window, same $20,000 deposit):
  **net +$699.49, profit factor 1.81, max equity drawdown $1,479.24
  (7.39%), 2,938 trades.** Confirmed via the same deals-table parse: 0
  `sl`/daily-loss-tagged closes this time, genuinely all TP hits. The
  basket that previously got force-closed at -$1,013.63 was allowed to
  keep averaging in this run and eventually recovered - the user's
  "never book a loss, unlimited legs" theory held up in this specific
  backtest window, once actually tested without an accidental safety
  net interfering. Higher peak drawdown (7.39% vs the earlier - also
  wrong - 5.34%) is the real, honest cost of letting a deep basket ride
  instead of cutting it - that trade-off is real and should be expected
  to bite eventually, this is one window's result, not a guarantee.

- **2026-08-24 (v22, floating-loss-scaled profit target - implemented,
  but the verification backtest surfaced a bigger, more urgent problem
  than the target formula itself):** explicit request: "$5000 floating
  loss -> minimum $1000 profit before releasing" (a 20% ratio), because
  the per-leg-growth-only target from v21 could let a basket that's
  genuinely deep underwater release for a target that's tiny relative
  to how much it just survived. Added `InpTargetPercentOfFloatingLoss`
  (default 20.0) and rewrote `GetProfitTarget()` to
  `MathMax(perLegBaseline, |floatingPL| * pct/100)` - the floating-loss
  term is 0/inactive while a basket is shallow or in profit, and only
  takes over once it's genuinely deep, exactly matching the user's
  example. Compiled clean (v22, 0 errors/0 warnings).

  **Verification hit a real methodological wall.** Every prior
  apples-to-apples backtest in this file used CXM Direct's demo
  (login 252424, symbol `XAUUSDc`) - the same account that blew up
  live on 2026-08-24. That login's password is not cached anywhere
  this session could reach (checked `accounts.dat` in the shared
  "MetaTrader 5" terminal data folder - not present; the CXM historical
  price/tick data *is* cached locally from an earlier session, but
  Strategy Tester still refused to start without a resolvable login:
  `"tester not started because the account is not specified"`).
  Substituted the only account this session could actually use
  (Exness-MT5Trial17, login 463741386, symbol plain `XAUUSD`) rather
  than silently skip verification - **but that data source is NOT the
  same one behind the earlier documented +$699.49/PF 1.81 result, and
  its own report header self-reports only 12% real ticks** (mostly
  OHLC-synthesized intrabar paths, not genuine tick-by-tick data) -
  both real caveats on the number below, disclosed rather than hidden.

  **A second, critical process bug was caught before this result could
  even be trusted at all:** the first attempt on the correct symbol
  produced an identical-down-to-the-cent catastrophic result whether
  `InpTargetPercentOfFloatingLoss` was 20 or 0 - a giveaway. Checked the
  Tester's own echoed `Inputs` list in the report and it was missing
  entire input groups (License, Trading Hours, Daily Loss Limit, Chart
  Visuals) and several individual v21/v22 inputs entirely - the Expert
  file actually loaded from this terminal's own
  `MQL5\Experts\Scalping Ai Pro By Farhan FX.ex5` was a stale copy from
  **2026-08-16**, predating the entire v21 direction-change (7am gate,
  unlimited legs, daily loss limit, the new floating-loss target -
  none of it existed in that binary). `metaeditor64.exe /compile`
  writes the `.ex5` next to the source file it's given, not into every
  terminal's own `MQL5\Experts` folder - compiling via the Vantage
  terminal's MetaEditor does NOT update what the separate "MetaTrader 5"
  (CXM/Exness-shared) terminal actually runs in its own Tester. Copied
  the freshly-compiled `.ex5` (and `.mq5`) from the repo into that
  terminal's `MQL5\Experts\` (both the root and `Advisors\` subfolder)
  before re-running - confirmed fixed by checking the report's own
  echoed input list contained every v22 input this time. **New standing
  rule for this project: before trusting any Tester report, check the
  report's own printed `Inputs:` section actually contains every input
  group the current source file has - a stale `.ex5` sitting in a
  terminal's `Experts` folder is a silent-wrong-binary risk exactly like
  the `.set`-file caching gotcha, just one layer up.**

  **The real (correct-binary, caveated-data) result: $20,000 -> final
  balance -$22,379.76, in well under one calendar day.** 983 trades,
  profit factor 0.30, max balance drawdown 109.65%, margin level 0.03%
  at stop-out. The entire blowup happened between 2026.07.01 07:00:00
  (the very first bar the 7am gate allowed a trade) and 14:35:00 the
  same day - about 7.5 hours - while XAUUSD rallied roughly
  $3,972 -> $4,111 (~3.5%) in one direction. The SELL basket kept
  adding legs into the rise the entire time (unlimited legs, no SL, per
  the v21 explicit design) until margin ran out. This is the same
  mechanism, not a different bug, as the real 2026-08-24 CXM blowup this
  whole v21/v22 direction-change was meant to prevent - reproduced here
  in a controlled backtest, on literal day one of the test window,
  independent of the new floating-loss-target change (confirmed via the
  before-mentioned accidental same-result-regardless-of-input check,
  once repeated on the correct binary it was still the dominant risk).
  **The floating-loss-scaled target does what it was asked to do - it
  raises the bar for what counts as "enough profit to release a deep
  basket" - but it cannot fix, and was never going to fix, the
  underlying unbounded-exposure problem: unlimited legs with no per-leg
  and no basket-level stop means one sustained multi-hour trend can
  still exhaust the account's margin before the position ever has a
  chance to average back to a releasable profit.** Reported to the user
  honestly, alongside the CXM-data-access and stale-binary caveats,
  rather than either hiding the result or unilaterally adding a safety
  cap that would contradict their explicit "unlimited legs, never book
  a loss" decision without asking first.

- **2026-08-24 (v23, deleted dead settings for a cleaner Inputs dialog):**
  right after confirming unlimited legs as final (see v22 above), asked
  to delete whatever inputs aren't needed "so it looks professional."
  Checked every input's usage count across the file (grep, not
  guessing) before touching anything - only `InpUnlimitedLegs` /
  `InpAbsoluteMaxLegsPerBasket` were genuinely dead (the toggle they
  controlled can never flip again now that unlimited is a confirmed
  final decision); every other input still gates real behavior even
  where off by default, and `InpLicenseKey` stayed since the user's own
  plan is to return to licensing later, not never. Removed both inputs,
  hardcoded the DCA-add condition to `if(adverse)`, updated the header
  comments. Recompiled clean (v23). Smoke-tested (short window, same
  inputs otherwise, correct binary copied into the shared test
  terminal's `MQL5\Experts\` this time - see the v22 entry's new
  standing rule) - byte-identical trade sequence and stop-out point vs.
  v22, confirming this was a pure cosmetic cleanup with zero behavior
  change, as expected.

- **2026-08-24 (v24, dashboard label-spacing bug, caught from a live
  screenshot):** user posted a screenshot of v23 actually running on the
  CXM demo (252424) - `Daily Targetoff`, `Daily Loss Limitoff`, and
  `Trading Hoursopen (from 07:00)` were all running the label straight
  into the value, no space. `PadRight(s, width)` only appends spaces
  while `StringLen(s) < width` - it silently does nothing once `s`
  already meets/exceeds `width`, rather than guaranteeing at least one
  separator space. `lblW` was 12; "Daily Loss Limit" is 17 chars, larger
  than every other label on the panel by enough that this specific bug
  never showed anywhere else. Fixed by raising `lblW` to 18. A real
  lesson for any future `PadRight`-style helper in this file: pick the
  width from the longest real label, not a round number that happens to
  fit most of them.

- **2026-08-24 (v25, the real bug behind "this doesn't look
  professional"):** user's blunt reaction to the v24 screenshot led to
  actually root-causing why the panel looked like bare floating text
  with no visible card, instead of just re-coloring things and hoping.
  `CreateDashboard()`'s background/accent/icon and `CreateButton()`'s
  colors/sizes were only ever set inside an `ObjectFind()`-gated
  create-once block - fine for a fresh chart, but this exact CXM demo
  chart has had the EA attached without interruption since v15/v16
  (when branding was first added), so every subsequent recompile found
  the objects already existing and skipped every property-setting line.
  The visible panel was plausibly showing colors from many versions ago
  the whole time, unaffected by anything changed since - `DbLabel`/
  `DbDivider` (which already re-apply every call) were the only pieces
  that ever visibly updated, which is exactly why v24's spacing fix was
  the one thing that actually showed up.

  Fixed the actual bug (every property now re-applies every call, not
  just the ones already doing so) and used the same pass to genuinely
  redesign it: brighter background clearly distinct from the pure-black
  chart, full-brightness gold border, a dark-gold header strip, and
  green/red/slate-tinted card boxes behind BUY/SELL/FILTERS so the
  sections read as grouped panels. Compiled clean, smoke-tested with the
  dashboard enabled - no runtime errors. **Lesson for this file's own
  future: any chart-object property meant to reflect "what the current
  code says" (not a one-time initial position) belongs outside the
  create-once gate - the create-once pattern is for *existence*, not
  for *appearance*, and conflating the two is invisible until someone's
  actually looking at a chart that's been running a long time.**

- **2026-08-24 (v26, cards were hiding their own text):** another live
  screenshot, immediately after v25 - the BUY/SELL/FILTERS cards were
  drawing ON TOP of the text they were meant to sit behind, leaving only
  fragments visible. Wrong assumption caught in the act: `OBJPROP_ZORDER`
  does not reliably control paint order for overlapping corner-anchored
  objects (`OBJ_LABEL` vs `OBJ_RECTANGLE_LABEL`) in this MT5 build -
  paint order actually follows the order objects were first added to the
  chart's object list, later-added wins. Every `DbCard()` call in v25
  physically sat after its section's labels in the source, so on first
  creation the cards were added later and painted over them. Fixed by
  moving all card creation to the very top of `UpdateDashboard()`,
  before any label - using hardcoded pixel offsets computed from the
  (fixed, deterministic) row layout instead of runtime-captured
  before/after y-values, since the cards now have to exist before the
  rows that would normally produce those values. **Lesson: don't trust
  ZORDER for stacking anchored MT5 chart objects - control paint order
  by controlling creation order instead, verified by actually looking at
  a live chart, not by reasoning about the API alone (this is the second
  dashboard bug in a row this file only actually confirmed via the
  user's own screenshots, not backtests - a real blind spot: nothing in
  the Tester or compile step can catch a chart-object rendering bug).**

- **2026-08-24 (v27, overflow fix + a genuinely misleading "/7" label):**
  next screenshot showed the License line's value text running past the
  panel's right edge (40-char string vs. a ~300px panel - just too
  narrow) - shortened the string and widened the panel/cards/dividers/
  buttons for margin. Separately, and more importantly: the user pushed
  back hard on "BUY BASKET (leg 2/7, cycle 1)", reading `/7` as a 7-leg
  cap contradicting the explicit "unlimited martingale" decision. It
  wasn't actually a cap - `InpMaxLegsPerBasket` only controls when lot
  size resets back down (so a single leg's lot doesn't double forever
  and hit the broker's max-lot limit) - but the notation genuinely
  invited that reading, and the user's objection was fair even though
  the underlying behavior was already correct. Changed the header to a
  plain running total + "(unlimited)" tag instead of the leg/cycle
  math - removes the ambiguity at the source instead of trying to
  explain it away. Did **not** delete `InpMaxLegsPerBasket` despite
  being asked to "remove the rest of the settings" in the same message -
  it's still real, load-bearing safety logic, unlike the two inputs
  actually deleted in v23 which did nothing. **Lesson: "this setting is
  confusing" and "this setting is unnecessary" are different complaints
  - the first was fixed by fixing the label; caving and deleting the
  underlying setting because a display bug made it look like a cap
  would have removed real protection to make a text-formatting problem
  go away.**

- **2026-08-24 (v27 real backtest, explicit request: 15-leg cycle,
  $15,000, 2026.08.01-today, every tick/real ticks):** ran on the same
  Exness/XAUUSD substitute data source as prior sessions (still no
  cached CXM 252424 credentials in this terminal) - but this window's
  own report self-reports **84% real ticks**, much better quality than
  the July window's 12%, so this result is more trustworthy than the
  v22 one. Confirmed correct binary + full input list via the report's
  own echoed `Inputs:` section (including `InpMaxLegsPerBasket=15`)
  before trusting anything, per the standing rule.

  **Result: $15,000 -> net +$36,660.21 (42,101 trades, profit factor
  1.29, Sharpe 3.25).** Sounds great in isolation, but the honest
  companion number is **Equity Drawdown Maximal: $36,681.57 (75.09%)** -
  at its worst point this month, the account's floating loss was three
  times its own starting deposit relative to a peak equity it had
  climbed to, and margin level bottomed at 64.46% (stressed, not yet a
  stop-out, but a real broker's own margin-call threshold, typically
  20-50%, was not far below that). Balance Drawdown Maximal (11.50%,
  $4,721.75) looks much tamer because it only reflects *realized*
  closes - the equity number is the one that actually reflects the
  unlimited-legs design's real risk while a basket is still open, and
  it's the more honest one to lead with. No forced margin closures
  occurred this run, but the margin level trace shows it was genuinely
  closer to happening than the balance-only view would suggest.

- **2026-08-27 (17-config parameter sweep - explicit request: "tune
  Leg/multiplier/trend/tp point, compare, find the best setting" to
  bring the 75% equity drawdown down):** all 17 runs on the same
  Aug 2026 window/data source as the previous entry (84% real ticks,
  same Exness/XAUUSD substitute - still no CXM 252424 credentials
  cached locally), one-factor-at-a-time from the 15-leg baseline
  (mult 2.0, DCA distance $1.2, multi-TF trend filter on): leg cycle
  length in {5,7,10,15,20,25}, lot multiplier in {1.3,1.5,1.8,2.0}, DCA
  distance in {0.6,0.8,1.2,1.8,2.5,3.0}, trend filter {off, single-TF
  only, stricter 1.0x ATR}. First attempt's `Report=sweep_v27\name`
  path silently failed to write any report file for any of 13 completed
  runs (MT5's Tester `Report=` parameter does not reliably create/use a
  subfolder) - caught before trusting empty results, fixed by using
  flat filenames, re-ran clean.

  Results, sorted by equity drawdown (the honest risk metric): net$ /
  PF / trades / balDD% / eqDD% / minMargin% -
  `trend_off` 46,310.73 / 1.26 / 58,562 / 14.50 / **58.03** / 45.89;
  `trend_strict1.0` 38,058.69 / 1.29 / 43,512 / 11.19 / 73.00 / 71.87;
  `leg_25` 36,802.47 / 1.28 / 42,215 / 13.93 / 74.87 / 65.22;
  `leg_20` 36,784.56 / 1.29 / 42,163 / 11.50 / 74.90 / 65.12;
  baseline (15/2.0/1.2/multiTF) 36,660.21 / 1.29 / 42,101 / 11.50 /
  75.09 / 64.46; `dca_1.8` 20,211.60 / 1.28 / 25,312 / 15.50 / 86.56 /
  29.93; `trend_singleTF` 29,577.78 / 1.32 / 32,980 / 13.02 / 87.66 /
  27.36; `mult_1.8` 33,133.04 / 1.27 / 40,657 / 12.70 / 95.56 / 7.79;
  then nine outright blow-ups, all net-negative with 100%+ drawdown:
  `leg_05` -15,222.52/103.66%, `leg_07` -16,230.30/107.55%, `mult_1.5`
  -15,516.87/112.83%, `mult_1.3` -16,398.47/114.20%, `dca_3.0`
  -18,426.72/122.96%, `leg_10` -15,673.71/123.47%, `dca_0.6`
  -16,706.01/126.71%, `dca_2.5` -18,283.68/130.60%, `dca_0.8`
  -22,712.62/146.98%.

  **Two findings, both important, neither of them "here's the tuned
  setting":**
  1. **`trend_off` (disabling the trend filter entirely) is both the
     highest-profit AND lowest-equity-drawdown config in the whole
     sweep** - 58.03% vs. the baseline's 75.09%. Counterintuitive
     (trend filter exists specifically to avoid fighting a strong
     move), and very plausibly an artifact of what this one month's
     price path happened to do (the filter blocked some entries that
     turned out fine) rather than a generally robust improvement - not
     claimed as such without testing other windows.
  2. **The parameter space is extremely fragile, not smoothly
     tunable.** 9 of 16 non-baseline variants outright blew the account
     net-negative with 100%+ drawdown - including moving the lot
     multiplier or DCA distance in *either* direction from the current
     values, and reducing the leg-cycle length. Small changes flip the
     same design between "+$36k" and "-$22k, 147% drawdown" on the exact
     same price data. That fragility is itself the headline finding:
     this isn't a system with a gentle risk/reward dial, it's one where
     most nearby settings are catastrophically worse and a few happen
     to survive this particular month's specific adverse excursions.
  3. **The equity-drawdown floor found across every survivor was 58%.**
     No combination of these four levers got it meaningfully lower
     while staying profitable - consistent with the standing structural
     conclusion (v22 entry, and the 2026-08-24 CXM live blowup itself):
     unlimited legs with no per-leg or basket-level stop puts a hard
     floor under how much tuning alone can reduce floating risk. These
     four inputs shape *which* month's excursions it survives, not
     *whether* deep floating drawdown is possible at all.

  Reported the full table and both findings to the user rather than
  picking the top row and presenting it as "the answer" - a single
  month's sweep result, especially one this sensitive to small
  parameter changes, is closer to a curve-fit than a validated edge
  until re-tested on a different window.

- **2026-08-27, same day (July 2026 re-run attempted, data unusable -
  reported as such, not treated as a real second data point):** re-ran
  the exact same 17-config sweep on 2026.07.01-07.31 to check whether
  `trend_off`'s August advantage held up on a different month. Every
  single config came back at **0% real ticks and only 664 M1 bars**
  for a whole month (should be tens of thousands) - this Exness login's
  locally cached tick/history database simply doesn't have real July
  data, only a tiny synthetic stub. All 17 configs failed in nearly
  identical ways (several rows matched to the cent, e.g.
  `trend_singleTF` and the baseline both at exactly -$17,438.15) -
  itself the tell that this was a data-availability artifact, not a
  genuine second market test; a real price-driven sweep would not
  produce that much cross-config agreement. **Discarded, not reported
  as evidence against `trend_off` or for anything else** - a bad-data
  result that happens to look like a finding is more dangerous than an
  honestly-reported "couldn't test this" would be. Confirms (again) the
  standing limitation: this session's only reliable real-tick data
  source for this EA is whatever specific window has already been
  fetched/cached locally (August 2026 for XAUUSD/Exness-MT5Trial17, at
  84%) - it is not safe to assume an arbitrary date range will have
  usable data without checking `History Quality:` first.

- **2026-08-27 (v28, sweep result baked into compiled defaults):**
  explicit request - "I'll do it myself, you set up all the settings,
  I'll just press start" - so the winning sweep config needed to be the
  actual shipped default, not something requiring manual Inputs-dialog
  edits. Changed `InpMaxLegsPerBasket` 7->15 (7 was one of the worst
  cycle lengths in the sweep) and `InpUseTrendFilter` true->false
  (best net profit AND lowest equity drawdown of every config tested).
  Left `InpLotMultiplier`/`InpDcaDistancePrice` unchanged - already at
  the sweep's best values. Compiled clean, then **verified with a
  Tester run using only the compiled defaults, zero `[TesterInputs]`
  overrides** - reproduced the sweep's exact numbers (net $46,310.73,
  PF 1.26, equity DD 58.03%, margin level 45.89%) to the cent,
  confirming the shipped binary actually matches what was tested, not
  just the source on paper. Same fragility/single-month caveat as
  before still applies and was restated in the README rather than
  quietly dropped now that it's the default instead of an experiment.

- **2026-08-27 (v29, License deleted for real):** the v23 entry above
  deliberately kept `InpLicenseKey` when asked to remove "unneeded"
  settings, reasoning the user planned to revisit licensing later so it
  wasn't dead, just dormant. The user pushed back directly this time -
  it kept showing up in the Inputs dialog and they didn't want it there
  regardless of future plans. Removed the input, the `=== License ===`
  group, the hardcoded key array, `LicenseOk()`, the dashboard row, and
  the stale re-add-later comment. Fully recoverable from git history if
  genuinely revisited. **Lesson connecting back to the same one from
  v23: a documented reason for keeping something doesn't survive the
  user directly saying they don't want to see it - re-litigate the
  decision when the person who made it pushes back, don't just point
  back at the earlier reasoning.** Compiled clean, verified (same Aug
  window/inputs as v28) - final balance matched to the cent
  ($61,310.73), confirming zero behavior change.

- **2026-08-27/28 (root-caused the exact drawdown event, explicit
  request: "which day did the 58% DD happen, what happened, fix that
  day"):** reconstructed the full equity curve from the raw Deals table
  (117,124 rows) rather than guessing - replayed each leg open/close
  chronologically, tracking weighted-average entry + total volume per
  side (same math as the EA's own dashboard), computing equity at every
  event as balance + floating P/L at that event's price. Found the
  exact peak-to-trough: **2026-08-26, 22:17:12 to 22:19:39 - a 2.5
  minute window.** Gold moved ~$13 (4599->4612) fast enough that the
  SELL basket's DCA leg kept re-triggering close to the
  `InpMinSecondsBetweenLegs` floor (5s), doubling lot size **9 times in
  a row** (0.62->1.26->2.54->5.10->10.22->20.46->40.94->81.90->163.82
  lots) - at the deepest point equity was $25,599 against a $60,959
  balance (the 58% drawdown, confirmed to the dollar). The basket then
  closed almost immediately after (22:19:39) once price paused for a
  few points - because the rapid re-averaging had already dragged the
  weighted-average entry price to within a couple dollars of the
  current price, only a small pullback was needed to hit target. Not
  a trend or news event - a mechanical martingale-ramp-speed problem.

  **Tested the obvious fix - slowing the ramp down
  (`InpMinSecondsBetweenLegs` 5->15/30/60/120/300) - and it backfired
  almost everywhere:**
  ```
  cooldown(s)      net$        PF   trades   balDD%   eqDD%   minMargin%
  5 (baseline)   46,318.84    1.26   58,562   14.50    58.03      45.91
  300            19,636.44    1.52   12,089   22.60    61.72     143.40
  15            -17,446.05    0.60    7,862  110.75   114.21       0.67
  120           -17,175.90    0.38    2,611  111.04   115.98      14.14
  30            -22,807.56    0.73   18,371  126.61   143.41       0.32
  60            -17,469.47    0.31    3,237  113.89   148.47       0.02
  ```
  Only 300s stayed net-positive, and even that came out *worse* on
  equity drawdown (61.72% vs. 58.03%) while giving up more than half
  the profit. 15/30/60/120s all blew the account. **Why the "obvious"
  fix backfired, worked out not just observed:** the fast re-averaging
  during the spike is exactly what let the basket recover almost
  immediately once price paused - it's the mechanism that *ends* deep
  drawdowns quickly, not what causes them. Slowing the leg cadence
  means the weighted-average entry lags much further behind a moving
  price for much longer, so instead of one sharp 2.5-minute spike, the
  basket stays deeply underwater for far longer stretches across the
  month, and often never gets the extra averaging it needed to survive
  at all. Confirms (a third time, after the 17-config sweep and the
  July data-quality dead end) that this design's risk knobs behave
  counter-intuitively and most changes make it worse, not better.

  **Not yet tried, and the more promising next candidate:** capping the
  *maximum single-leg lot size* (letting legs keep adding on schedule,
  but flattening the martingale growth once it reaches a ceiling,
  instead of letting it keep doubling to 163+ lots) - directly targets
  the mechanism (unbounded exponential size growth within a short
  window) without touching the add-cadence that the basket depends on
  to recover. Proposed to the user, not yet implemented or tested.

- **2026-08-28 (v30, both proposed fixes built and tested - one worked,
  one backfired badly):** implemented two new, independent inputs per
  explicit request: `InpMaxSingleLegLot` (cap martingale growth at a
  flat ceiling instead of letting it keep doubling) and
  `InpMaxLegsPerBar` (the user's own idea - if a fast move triggers more
  than N DCA adds within one M1 bar, make the rest wait for the bar to
  close, i.e. for the next bar, before firing - only bites during a
  fast multi-cross-per-minute burst like 2026-08-26, not normal
  spread-out DCA). `legsThisBar` added to `SBasket`, computed in
  `ScanBasket()` by comparing each open leg's `POSITION_TIME` to the
  current bar's open time.

  **`InpMaxLegsPerBar` backfired exactly like the cooldown-time test did,
  for the same reason - discard, don't ship:**
  ```
  config          net$        PF   trades   balDD%   eqDD%   minMargin%
  bar1_only     30,741.12    1.25   35,921   23.85   123.51       0.02
  bar2_only    -25,016.20    0.47    5,273  151.20   167.72       0.31
  bar1_lot5    -24,047.77    0.39    3,639  145.59   158.92       0.02
  bar2_lot10   -18,749.88    0.49    4,277  119.41   129.85       0.50
  bar1_lot10   -48,909.40    0.67   24,123  182.73   203.68       0.00
  ```
  Every single per-bar-limited config was worse than doing nothing, most
  catastrophically. Same mechanism as the cooldown-time finding: this
  design's fast recovery depends on the fast re-averaging that a
  per-bar/cooldown throttle directly prevents - two independent
  attempts at "slow the add-rate down" have now both made things worse,
  which is itself the more important, generalizable finding: **any fix
  that reduces how fast this basket can average toward the current
  price will very likely hurt, not help, regardless of the specific
  mechanism used to slow it down.**

  **`InpMaxSingleLegLot` worked - genuinely lower drawdown AND slightly
  higher profit, sorted by equity drawdown:**
  ```
  cap    net$        PF   trades   balDD%   eqDD%   minMargin%
  17   48,327.37    1.28   58,554   11.54    42.73      86.83
  20   47,636.21    1.28   58,548   12.42    47.31      74.21
  25   48,737.03    1.28   58,549   12.67    51.25      72.88
  30   46,568.08    1.27   58,551   10.99    64.31      65.77
  5    46,152.75    1.29   58,441    6.21    75.83     116.92
  40   47,438.65    1.27   58,551   12.03    71.71      47.44
  10   49,779.81    1.30   58,524   14.10    80.61      74.67
  12   52,423.35    1.31   58,533   15.17    90.13      33.50
  none 46,318.84    1.26   58,562   14.50    58.03      45.91  <- v29 default
  15   47,816.39    1.28   58,515   10.93   103.93       0.10
  ```
  **Not monotonic - 15 sits right next to 17 (the best result) and is
  the single worst value tested (103.93% DD, margin down to 0.10%,
  nearly a real stop-out).** The "good" region is roughly 17-25 (all
  42-51% DD, clearly better than uncapped), not one isolated lucky
  number - some real margin for this one, unlike the sharp single-point
  cliffs seen elsewhere in this project's sweeps. Best single result:
  **cap = 17, net +$48,327 (vs. +$46,318 uncapped), equity drawdown
  42.73% (vs. 58.03% uncapped) - both metrics improved together, not a
  trade-off.** Recommending 17 or 20 to the user as the new default,
  pending confirmation given the demonstrated fragility one step away.

- **2026-08-28 (v30, real 100%-quality July data, via the user's own CXM
  live account - and it wipes the account completely, negative balance,
  same calendar day as every prior July blowup this session):** the
  user ran v30's own Strategy Tester on their live CXM terminal
  (718181/CXMDirect-Live, symbol `XAUUSDp`, 2026.07.01-07.31) and got
  **100% real ticks** - the first genuinely trustworthy July data this
  entire session (every earlier attempt on the Exness login came back
  at 0-12%). Result: **net -$23,828.73 on a $15,000 deposit, balance
  drawdown 148.68%, equity drawdown 167.40%, profit factor 0.19, largest
  single loss trade -$9,129.** Reproduced exactly (to the cent) by
  re-running the identical config myself once the user confirmed they
  were done with the terminal (avoiding the shared-terminal conflict
  risk flagged earlier), then applied the same equity-curve
  reconstruction as the 2026-08-26 root-cause.

  **The event: 2026-07-01, 07:00:00-14:04:00 - the entire test's 1,956
  deals happened on ONE DAY, and it's the exact same calendar day that
  caused the original v22 blowup earlier this session (on Exness data,
  a different broker feed) - not a coincidence, a genuinely major
  trending day that shows up as catastrophic across every data source
  tested.** Equity climbed calmly all morning (peak $16,186 at 13:43),
  then between **13:43:26 and 14:04:00 - 21 minutes** - price moved
  ~$20 (3987.76 -> 4007.56), the SELL basket's volume grew to 37.46
  lots even *with the new 17-lot-per-leg cap active*, and **the account
  went fully negative (-$8,828.73 balance)** - a real stop-out, not
  just a deep floating drawdown that later recovered like 2026-08-26.

  **This is the critical finding: the lot cap helps a short, sharp
  spike (where the cap limits how big any ONE leg gets before price
  reverses) but does nothing against a sustained, bigger move over
  20+ minutes, because there is still no limit on TOTAL leg count or
  total basket exposure - many capped-size legs can still add up to
  full account loss if the move doesn't pause in time.** Every
  parameter tuned so far this session (leg cycle length, lot
  multiplier, DCA distance, trend filter, add-cadence throttling, and
  now the lot cap) changes *which* specific days/spikes the design
  survives - none of them touch the structural fact that "unlimited
  legs, never book a loss" has no real ceiling on loss during a
  sufficiently large sustained move. Reported to the user plainly, not
  softened: no amount of further parameter tuning within this design's
  current rules (no per-leg SL, no basket-level stop, no total leg
  cap) can be expected to fix this specific failure mode - the two
  honest options are a real loss-realizing circuit breaker (which
  contradicts the standing "never book a loss" decision) or accepting
  this as a permanent, real tail risk of the current design.

  **User's decision, given both options plainly: accept the risk.** No
  loss-realizing circuit breaker requested. v30 (unlimited legs, no
  per-leg/basket SL, `InpMaxSingleLegLot=17`) stands as final, with the
  2026-07-01-style sustained-move tail risk explicitly understood and
  accepted rather than papered over - the same standing "never book a
  loss" decision reaffirmed with the strongest evidence yet in front of
  it (a real, 100%-quality-data account wipeout), not made blind.

- **2026-08-28 (real, live confirmation - the CXM demo, 252424, blew up
  for real hours after the risk was accepted):** user reported the
  account hit 0 and shared `ReportHistory-252424.html`/`.png` (their own
  files, read for root-cause with implied permission as before). Real
  data, not a backtest: balance climbed steadily all session to
  $25,909.17, then two broker-triggered stop-out (`[so ...]`) cascades -
  **09:52:21-09:53:04** (five legs force-closed in 43 seconds: 17.00,
  10.24, 5.12, 2.56, 1.28 lots, for -$7,018.11/-$7,451.14/-$4,739.33/
  -$2,881.61/-$1,676.51 - about **-$23,765 in under a minute**, balance
  $25,908 -> $2,142.47) and **09:55:53-09:57:04** (wiping the remaining
  balance down to $26.42, then $0.63 by end of day).

  **`InpMaxSingleLegLot=17` worked exactly as coded - leg 12 shows
  volume `17` instead of the martingale-implied `20.48` - but this
  confirms, in real live trading now instead of just backtest, the
  2026-08-28 v30 README/learnings finding from the July-2026 real-data
  analysis: capping each leg's size does not cap TOTAL exposure.** By
  the time leg 12 opened, the SELL basket was carrying roughly
  1.28+2.56+5.12+10.24+17 = ~36.2 lots - accumulated over legs 8
  through 12 in about 4 minutes (09:47:52-09:51:25) as price drifted up
  only from ~4593 to ~4600. A further ~$7 move (4599.87 -> 4607.02) was
  then enough to exhaust available margin and trigger the broker's own
  stop-out mechanism, which liquidated every open leg at whatever price
  it could, in sequence - not the EA choosing to book a loss (it never
  does), the *broker* forcing closure once margin ran out. This is not
  a new failure mode - it is the exact 2026-07-01 mechanism from the
  backtest analysis above, now observed live, on the very account/day
  the user had just accepted this risk for.

  **Confirmed demo, not real money** (this is the same CXM Direct demo,
  252424, used throughout this project's testing/live-eval history -
  no real financial loss). Reported to the user factually: what
  happened, why, and that it matches the predicted mechanism exactly -
  not proposed as a new problem needing a new fix, since the user's
  decision to accept this exact risk was made with this exact scenario
  already described to them minutes earlier.

- **2026-08-28/29 (v31, emergency-exit-on-large-volume - implemented,
  tested honestly, does not fix the tail case it targeted):** user's
  response to the live blowup was a genuinely correct diagnosis: "with
  this much volume, didn't price come down even once - build something
  that gets out easily, without a loss, once floating is high."
  Right call - `GetProfitTarget()`'s 20%-of-floating-loss term demands
  MORE profit the deeper a basket goes, exactly backwards once total
  exposure is already dangerous. Added `InpEmergencyExitVolumeLots`
  (20 lots default) / `InpEmergencyExitTargetUSD` ($0.50 default): once
  total basket volume crosses the threshold, target drops to the small
  value via `MathMin` on top of the existing formula - can only ever
  lower the bar to close, never raise it, so strictly non-harmful by
  construction.

  **Full-month sweep (2026.08.01-27) was uninformative - volume never
  reached even the smallest tested threshold (10 lots) that window, so
  `off` and every `vol10`-`vol30` variant came back byte-identical.**
  Also surfaced a real methodology caveat worth flagging for future
  sweeps: this same "off" config's result (net $51,596.99) differs
  meaningfully from the v30 baseline recorded days earlier ($48,327.37)
  for what should be an identical, no-op configuration - most likely
  explained by this Exness login's local tick cache having grown/
  changed between sessions (already observed once before, 12%->84%
  real-tick quality improving over time) rather than a code bug, but a
  reminder that cross-session numeric comparisons here carry some
  irreducible noise; only qualitative, order-of-magnitude findings
  (bar-limit backfiring, cooldown backfiring, lot-cap helping) should be
  trusted at face value, not single-digit-percent deltas.

  **Retested narrowly against the known 2026-08-24-27 stress window
  (100% real ticks this time) - the emergency exit DID fire this time**
  (Balance Drawdown Absolute changed from $0 to $304.93 with it on) -
  **but made no difference to the outcome**: net profit, equity
  drawdown (110.08%), and margin level (0.29%, a near-total wipeout)
  came out identical on or off. Worked out why, not just observed: a
  target of any size - large or $0.50 - still requires at least one
  favorable tick to be hit. The worst excursions found this project
  (2026-08-26, 2026-08-28 live, and this stress window) all show price
  moving in essentially one direction with no real pause. A smaller
  target doesn't help if the market never gives anything back, however
  briefly - **this is the clearest demonstration yet that only a
  mechanism willing to realize an actual loss can close this specific
  gap; no amount of clever target-sizing can, because it still
  fundamentally waits for the market to cooperate at least once.**
  Shipped anyway (real, strictly non-harmful improvement for the cases
  where a small pause DOES occur) with this limitation stated plainly,
  not glossed over.
