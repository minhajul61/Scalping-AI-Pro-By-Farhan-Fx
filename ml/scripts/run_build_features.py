import glob
import sys
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT_DIR))
sys.path.insert(0, str(ROOT_DIR / "src"))

import pandas as pd

from config import settings
from dca_ml.features.feature_engineering import build_all_features, ALL_FEATURE_COLS
from dca_ml.util.logging_setup import get_logger

log = get_logger("run_build_features")


def _latest(pattern):
    matches = sorted(glob.glob(str(settings.DATA_RAW_DIR / pattern)))
    if not matches:
        raise FileNotFoundError(f"No files matching {pattern} in {settings.DATA_RAW_DIR}")
    return matches[-1]


def main():
    m1_path = _latest(f"{settings.SYMBOL}_M1_*.csv")
    h1_path = _latest(f"{settings.SYMBOL}_H1_*.csv")
    d1_path = _latest(f"{settings.SYMBOL}_D1_*.csv")
    log.info(f"Loading M1={m1_path}, H1={h1_path}, D1={d1_path}")

    df_m1 = pd.read_csv(m1_path, parse_dates=["time"])
    df_h1 = pd.read_csv(h1_path, parse_dates=["time"])
    df_d1 = pd.read_csv(d1_path, parse_dates=["time"])

    merged = build_all_features(df_m1, df_h1, df_d1)

    log.info(f"Built features: {len(merged)} rows, columns: {list(merged.columns)}")
    log.info(f"NaN counts per feature:\n{merged[ALL_FEATURE_COLS].isna().sum()}")
    log.info(f"Sample (last 5 rows):\n{merged[['time'] + ALL_FEATURE_COLS].tail(5).to_string()}")

    settings.DATA_PROCESSED_DIR.mkdir(parents=True, exist_ok=True)
    out_path = settings.DATA_PROCESSED_DIR / "m1_with_features.parquet"
    merged.to_parquet(out_path, index=False)
    log.info(f"Saved to {out_path}")


if __name__ == "__main__":
    main()
