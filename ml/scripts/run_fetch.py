import argparse
import sys
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT_DIR))
sys.path.insert(0, str(ROOT_DIR / "src"))

from config import settings
from dca_ml.data.fetch_history import fetch, save


def main():
    parser = argparse.ArgumentParser(description="Pull historical OHLCV from MT5 (M1, H1, D1)")
    parser.add_argument("--symbol", default=settings.SYMBOL)
    parser.add_argument("--timeframe", default="all", help="M1, H1, D1, or 'all' (default)")
    parser.add_argument("--months", type=float, default=None)
    args = parser.parse_args()

    timeframes = ["M1", "H1", "D1"] if args.timeframe == "all" else [args.timeframe]

    for tf in timeframes:
        df = fetch(symbol=args.symbol, timeframe=tf, months=args.months)
        save(df, symbol=args.symbol, timeframe=tf)


if __name__ == "__main__":
    main()
