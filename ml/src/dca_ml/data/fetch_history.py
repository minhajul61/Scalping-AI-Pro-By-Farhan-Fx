"""Ported from the sibling project's fetch_history.py (same chunk-and-walk-
backward pattern), extended with D1 (the EA's own regime detector runs on
D1; the sibling project only ever needed M1/H1). Never hardcode an assumed
history depth - this always self-reports the real floor, since brokers/demo
accounts can and do change history depth over time (already seen twice in
this EA's own learnings.md: ~101 days M1, then later ~480-576 days D1)."""
from datetime import datetime, timedelta

import pandas as pd
import MetaTrader5 as mt5

from config import settings
from dca_ml.data.mt5_client import connect, shutdown
from dca_ml.util.logging_setup import get_logger

log = get_logger("fetch_history")

TIMEFRAME_MAP = {
    "M1": mt5.TIMEFRAME_M1,
    "M5": mt5.TIMEFRAME_M5,
    "H1": mt5.TIMEFRAME_H1,
    "D1": mt5.TIMEFRAME_D1,
}

BARS_PER_DAY = {"M1": 24 * 60, "M5": 24 * 12, "H1": 24, "D1": 1}

# copy_rates_range/copy_rates_from_pos return nothing above ~90-100k bars per
# single call (observed cap, same as the sibling project). Chunk requests
# below that so a large months= value pulls everything the server actually
# has, not just whatever fits in one call.
SAFE_BARS_PER_CALL = 80_000


def _fetch_chunk(symbol, tf, date_from, date_to):
    return mt5.copy_rates_range(symbol, tf, date_from, date_to)


def fetch(symbol=None, timeframe="M1", months=None):
    """Chunks the request into windows under SAFE_BARS_PER_CALL and walks
    backward from now, concatenating, until either the requested months is
    covered or the server returns nothing further back (i.e. that's the true
    start of available history for this symbol/account - not a client-side
    cap). Logs clearly which case ended the fetch."""
    symbol = symbol or settings.SYMBOL
    if months is None:
        months = {
            "M1": settings.M1_HISTORY_MONTHS,
            "H1": settings.H1_HISTORY_MONTHS,
            "D1": settings.D1_HISTORY_MONTHS,
        }.get(timeframe, 12)
    tf = TIMEFRAME_MAP[timeframe]
    bars_per_day = BARS_PER_DAY.get(timeframe, 24 * 60)
    chunk_days = max(1, SAFE_BARS_PER_CALL // bars_per_day)

    # verify_account=True (unlike the sibling project's read-only default):
    # a stray/mismatched terminal instance was observed silently answering
    # mt5.initialize() during this project's own setup - fail loudly instead
    # of risking price history pulled from the wrong server/account.
    connect(verify_account=True)
    try:
        oldest_wanted = datetime.now() - timedelta(days=months * 30)
        chunks = []
        window_end = datetime.now()
        hit_history_floor = False

        while window_end > oldest_wanted:
            window_start = max(oldest_wanted, window_end - timedelta(days=chunk_days))
            rates = _fetch_chunk(symbol, tf, window_start, window_end)
            if rates is None or len(rates) == 0:
                log.info(f"No data for window {window_start} to {window_end} - "
                         f"reached the start of available history.")
                hit_history_floor = True
                break

            chunk_df = pd.DataFrame(rates)
            chunk_df["time"] = pd.to_datetime(chunk_df["time"], unit="s")
            chunks.append(chunk_df)

            earliest_in_chunk = chunk_df["time"].min()
            if earliest_in_chunk >= window_start + timedelta(hours=1):
                # Server returned less than the window asked for - we've hit
                # the true start of history, not a per-call size cap.
                hit_history_floor = True
                break
            window_end = earliest_in_chunk

        if not chunks:
            raise RuntimeError(f"No rates returned for {symbol} {timeframe} at all: {mt5.last_error()}")

        df = pd.concat(chunks, ignore_index=True)
        df = df.drop_duplicates(subset="time").sort_values("time").reset_index(drop=True)

        actual_days = (df["time"].max() - df["time"].min()).days
        log.info(f"Fetched {len(df)} {timeframe} bars for {symbol} "
                 f"({df['time'].min()} to {df['time'].max()}, ~{actual_days}d) "
                 f"across {len(chunks)} chunk(s)")
        if hit_history_floor and actual_days < months * 28:
            log.warning(
                f"Requested {months} months but only ~{actual_days} days of history "
                f"actually exist on this account/server for {symbol} {timeframe} - this "
                f"is the true start of available data, not a client-side limit."
            )
        return df
    finally:
        shutdown()


def save(df, symbol=None, timeframe="M1"):
    symbol = symbol or settings.SYMBOL
    settings.DATA_RAW_DIR.mkdir(parents=True, exist_ok=True)
    start = df["time"].min().strftime("%Y%m%d")
    end = df["time"].max().strftime("%Y%m%d")
    path = settings.DATA_RAW_DIR / f"{symbol}_{timeframe}_{start}_{end}.csv"
    df.to_csv(path, index=False)
    log.info(f"Saved to {path}")
    return path
