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
