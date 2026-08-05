"""Single source of truth for all tunable parameters. No magic numbers elsewhere.

Ported from the sibling project's settings.py pattern (E:\\Scalping AI Pro By
Farhan Fx\\config\\settings.py) - same account/server, since this pulls
history from the same local backtesting terminal used throughout this EA's
own Strategy Tester workflow.
"""
import os
from pathlib import Path
from dotenv import load_dotenv

ROOT_DIR = Path(__file__).resolve().parent.parent
load_dotenv(ROOT_DIR / ".env")

# --- Broker / account (local backtesting terminal, same one used for this
# EA's Strategy Tester runs throughout learnings.md) ---
MT5_LOGIN = int(os.getenv("MT5_LOGIN", "416045126"))
MT5_PASSWORD = os.getenv("MT5_PASSWORD", "")
MT5_SERVER = os.getenv("MT5_SERVER", "Exness-MT5Trial14")
MT5_TERMINAL_PATH = os.getenv("MT5_TERMINAL_PATH", r"C:\Program Files\MetaTrader 5\terminal64.exe")
EXPECTED_ACCOUNT = MT5_LOGIN

# --- Instrument ---
SYMBOL = "XAUUSD"
BASE_TIMEFRAME = "M1"

# --- Data history requests (real ceilings are self-reported by
# fetch_history.py, never hardcoded - see learnings.md for the two floors
# already discovered: ~101 days M1 by the sibling project, ~480-576 days D1
# by this EA's own regime detector) ---
M1_HISTORY_MONTHS = 12
H1_HISTORY_MONTHS = 12
D1_HISTORY_MONTHS = 60

# --- EA parameters this pipeline must mirror exactly (from
# "Scalping Ai Pro By Farhan FX.mq5" as of 2026-07-31) - keep in sync by hand;
# there is no automated import from the .mq5 file. ---
EA_MAGIC = 20270115
EA_TREND_TF = "H1"
EA_TREND_MA_PERIOD = 50
EA_TREND_ATR_PERIOD = 14
EA_TREND_STRENGTH_ATR_MULT = 0.5
EA_REGIME_TREND_PERCENTILE = 70.0
EA_REGIME_VOL_PERCENTILE = 80.0
EA_INITIAL_LOT = 0.02
EA_LOT_MULTIPLIER = 2.0            # current FINAL value (was 1.5)
EA_DCA_DISTANCE_USD = 3.0
EA_MAX_LEGS_PER_CYCLE = 7          # InpMaxLegsPerBasket - self-tuned to 6 live right now
EA_ABSOLUTE_MAX_LEGS = 50
EA_BASE_PROFIT_TARGET_USD = 2.0
EA_CYCLE_TARGET_GROWTH = 0.5
EA_STUCK_BASKET_HOURS = 4.0        # hours stuck at a full cycle before relief starts easing target
EA_STUCK_BASKET_DECAY_HOURS = 8.0
EA_STUCK_BASKET_TARGET_FLOOR = 0.0
EA_CATASTROPHIC_SL = False         # FINAL: off, per explicit user decision (see EA's own learnings.md 2026-07-31)
EA_ATR_PERIOD = 14                 # InpAtrPeriod (M1, for the ATR-spike filter)
EA_ATR_BASELINE_BARS = 20          # InpAtrBaselineBars
EA_MAX_ATR_RATIO = 1.5             # InpMaxAtrRatio
EA_REGIME_TRENDING_DCA_MULT = 1.3  # InpRegimeTrendingDcaDistanceMult
EA_REGIME_RANGING_DCA_MULT = 0.85  # InpRegimeRangingDcaDistanceMult
EA_REGIME_VOLATILE_LOT_CAP = 1.2   # InpRegimeVolatileLotMultCap
EA_LOT_STEP = 0.01
EA_MIN_LOT = 0.01
EA_MAX_LOT = 500.0                 # typical broker ceiling for this symbol - essentially never binds here
EA_MAX_SPREAD_POINTS = 300          # InpMaxSpreadPoints, not modeled precisely in the replay (see basket_simulator docstring)

# --- Replay simplifications (documented, not silent) ---
# The offline replay in basket_simulator.py does NOT model: (a) the daily
# self-tuner's small day-to-day nudges to distance/multiplier/target/cycle
# length (uses the static Inp* defaults above throughout); (b) the intraday
# soft-brake (depends on live running account equity, not just price
# history); (c) real bid/ask spread (uses each M1 bar's close price for
# both entry sides - spread is ~$0.15-0.30 on this symbol, small relative
# to the $3 DCA distance and $2+ profit targets, so this does not change
# which decisions get made, only shifts realized P&L by a few cents/leg).
# Market regime detection (D1 percentile-based distance/lot-cap adjustment)
# IS modeled, since it's fully determined by price history alone.

# --- Labeling: trend continuation ---
TREND_LABEL_HORIZONS_MIN = [30, 60, 120]
TREND_LABEL_NOISE_FLOOR_ATR_MULT = 0.25  # continuation_return must beat this many ATRs to count as a real move

# --- Labeling: stuck-basket risk ---
# A leg-add decision is labeled 1 if the resulting basket reaches >= 1 full
# cycle (EA_MAX_LEGS_PER_CYCLE legs) AND stays open beyond
# EA_STUCK_BASKET_HOURS past its last leg without reaching
# GetEffectiveProfitTarget(). Baskets still open at data end are censored
# (dropped), never force-labeled.
STUCK_LABEL_MIN_POSITIVE_EVENTS = 30  # go/no-go floor - see Phase 5 in the plan

# --- Model training ---
CHRONOLOGICAL_SPLIT = (0.6, 0.2, 0.2)  # train / validation / holdout, no shuffling, holdout touched once
RANDOM_STATE = 42
LIGHTGBM_PARAMS = dict(
    n_estimators=300,
    max_depth=6,
    learning_rate=0.05,
    min_child_samples=100,
    random_state=RANDOM_STATE,
    verbose=-1,
)
RANDOM_FOREST_PARAMS = dict(
    n_estimators=300,
    max_depth=8,
    min_samples_leaf=100,
    random_state=RANDOM_STATE,
    n_jobs=-1,
)
LOGISTIC_PARAMS = dict(
    max_iter=1000,
    class_weight="balanced",
    random_state=RANDOM_STATE,
)
# Stuck-risk model specifically: shallow + regularized, positive class will
# be rare - a high-capacity model would just memorize the few positives.
STUCK_MODEL_MAX_DEPTH = 3

# --- ONNX export ---
ONNX_OPSET = 15
ONNX_VALIDATION_TOLERANCE = 1e-5

# --- Paths ---
DATA_RAW_DIR = ROOT_DIR / "data" / "raw"
DATA_PROCESSED_DIR = ROOT_DIR / "data" / "processed"
MODELS_DIR = ROOT_DIR / "models"
LOGS_DIR = ROOT_DIR / "logs"
LEARNINGS_FILE = ROOT_DIR / "learnings.md"

# Where the MQL5 EA will look for the exported .onnx files at runtime
# (terminal-specific MQL5\Files\, matching WriteTuningLog's existing
# pattern - not the shared Common folder).
MQL5_MODEL_SUBFOLDER = "DCA_ML"
