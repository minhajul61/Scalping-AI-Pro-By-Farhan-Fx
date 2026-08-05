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
