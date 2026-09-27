#!/usr/bin/env python3
"""Download Dukascopy XAUUSD BID M1 candles.

Month in the URL is zero-based. Times inside each file are seconds from
00:00 UTC of that calendar day. Weekends and missing days are skipped.
"""
from __future__ import annotations

import argparse
import lzma
import struct
import time
from datetime import date, timedelta
from pathlib import Path

import numpy as np
import pandas as pd

URL = "https://datafeed.dukascopy.com/datafeed/XAUUSD/{year}/{month0:02d}/{day:02d}/BID_candles_min_1.bi5"
UA = "Mozilla/5.0 (compatible; research-backtest/1.0)"


def daterange(start: date, end: date):
    d = start
    while d <= end:
        yield d
        d += timedelta(days=1)


def fetch_day(d: date, retries: int = 3) -> bytes | None:
    import subprocess
    import tempfile

    url = URL.format(year=d.year, month0=d.month - 1, day=d.day)
    for attempt in range(retries):
        tmp = tempfile.NamedTemporaryFile(delete=False)
        tmp.close()
        proc = subprocess.run(
            ["curl", "-fsSL", "-A", UA, "--max-time", "40", "--retry", "2", "--retry-all-errors", "-o", tmp.name, url],
            capture_output=True,
            text=True,
        )
        if proc.returncode == 0:
            data = Path(tmp.name).read_bytes()
            Path(tmp.name).unlink(missing_ok=True)
            if data:
                return data
        else:
            err = (proc.stderr or "").strip().splitlines()
            tail = err[-1] if err else f"exit {proc.returncode}"
            if "404" in tail or "403" in tail:
                Path(tmp.name).unlink(missing_ok=True)
                return None
            print(f"retry {d} attempt {attempt + 1}: {tail}", flush=True)
        Path(tmp.name).unlink(missing_ok=True)
        time.sleep(1.0 + attempt)
    print(f"FAILED {d}", flush=True)
    return None


def decode(raw: bytes, d: date) -> pd.DataFrame:
    data = lzma.decompress(raw)
    n = len(data) // 24
    times = np.empty(n, dtype="datetime64[s]")
    o = np.empty(n)
    h = np.empty(n)
    l = np.empty(n)
    c = np.empty(n)
    base = np.datetime64(d.isoformat(), "s")
    for i in range(n):
        chunk = data[i * 24 : (i + 1) * 24]
        sec, op, cl, lo, hi = struct.unpack(">5I", chunk[:20])
        times[i] = base + np.timedelta64(int(sec), "s")
        o[i] = op / 1000.0
        c[i] = cl / 1000.0
        l[i] = lo / 1000.0
        h[i] = hi / 1000.0
    return pd.DataFrame({"time": times, "open": o, "high": h, "low": l, "close": c})


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--start", default="2026-06-01")
    p.add_argument("--end", default="2026-09-26")
    p.add_argument("--out", default="sim/data/xauusd_m1_duka.parquet")
    args = p.parse_args()
    start = date.fromisoformat(args.start)
    end = date.fromisoformat(args.end)
    days = [d for d in daterange(start, end) if d.weekday() < 5]
    cache = Path(args.out).parent / "days"
    cache.mkdir(parents=True, exist_ok=True)
    frames = []
    missing = []
    for i, d in enumerate(days, 1):
        cached = cache / f"{d.isoformat()}.parquet"
        if cached.exists():
            df = pd.read_parquet(cached)
            frames.append(df)
            print(f"cache {d} bars={len(df)} ({i}/{len(days)})", flush=True)
            continue
        raw = fetch_day(d)
        if raw is None:
            missing.append(d.isoformat())
            print(f"skip {d} ({i}/{len(days)})", flush=True)
            time.sleep(0.4)
            continue
        df = decode(raw, d)
        df.to_parquet(cached, index=False)
        frames.append(df)
        print(f"{d} bars={len(df)} close={df['close'].iloc[-1]:.2f} ({i}/{len(days)})", flush=True)
        time.sleep(0.25)
    if not frames:
        raise SystemExit("no data downloaded")
    all_df = pd.concat(frames, ignore_index=True)
    all_df = all_df.drop_duplicates(subset="time").sort_values("time")
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    all_df.to_parquet(out, index=False)
    print(f"wrote {out} rows={len(all_df)} {all_df['time'].iloc[0]} -> {all_df['time'].iloc[-1]} missing={len(missing)}", flush=True)
    if missing:
        print("missing " + ",".join(missing), flush=True)


if __name__ == "__main__":
    main()
