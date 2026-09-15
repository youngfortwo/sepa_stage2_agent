#!/usr/bin/env python3
"""TEMP probe: estimate market-wide hit rate of the proposed 右侧刚启动 branch.

Not part of the product. Samples N random stocks, evaluates the existing 左侧
logic and a prototype 右侧 branch, and sweeps the right-side thresholds.
"""
from __future__ import annotations

import random
import sys
import time

import pandas as pd

from sepa_stage2_scanner import fetch_history, get_stock_pool
from oversold_rebound_scanner import evaluate_oversold_rebound, is_risk_name

SAMPLE = int(sys.argv[1]) if len(sys.argv) > 1 else 400
MUST_INCLUDE = ["002487", "002531"]
SEED = 42


def right_side_metrics(h: pd.DataFrame) -> dict | None:
    """Compute the raw metrics the 右侧 branch would key off."""
    if len(h) < 90:
        return None
    c = h["close"].astype(float).reset_index(drop=True)
    hi = h["high"].astype(float).reset_index(drop=True)
    lo = h["low"].astype(float).reset_index(drop=True)
    v = h["volume"].astype(float).reset_index(drop=True)

    ma5 = c.rolling(5).mean()
    ma13 = c.rolling(13).mean()
    ma30 = c.rolling(30).mean()

    # consecutive days (counting back from today) with close above MA30
    days_above = 0
    for i in range(len(c) - 1, -1, -1):
        if pd.isna(ma30.iloc[i]) or c.iloc[i] <= ma30.iloc[i]:
            break
        days_above += 1

    vol30 = float(v.rolling(30).mean().iloc[-1])
    vol3_max = float(v.tail(3).max())
    hh60, ll60 = float(hi.tail(60).max()), float(lo.tail(60).min())
    hh90 = float(hi.tail(90).max())
    close = float(c.iloc[-1])

    return {
        "days_above_ma30": days_above,
        "vol_surge": vol3_max / vol30 if vol30 > 0 else 0.0,
        "ma5_gt_ma13": float(ma5.iloc[-1]) > float(ma13.iloc[-1]),
        "rebound_pct": (close / ll60 - 1) * 100 if ll60 > 0 else 0.0,
        "drawdown_pct": (hh60 - ll60) / hh60 * 100 if hh60 > 0 else 0.0,
        "not_broken": close < hh90 * 0.75,
    }


def right_side_match(m: dict, max_days: int, min_surge: float, max_rebound: float) -> bool:
    return (m["drawdown_pct"] >= 30.0
            and m["not_broken"]
            and 1 <= m["days_above_ma30"] <= max_days
            and m["vol_surge"] >= min_surge
            and m["ma5_gt_ma13"]
            and m["rebound_pct"] < max_rebound)


def main() -> int:
    pool = get_stock_pool(False, 5000, 0)
    pool = pool[~pool["名称"].apply(is_risk_name)].reset_index(drop=True)
    codes = pool["代码"].tolist()
    names = dict(zip(pool["代码"], pool["名称"]))

    random.seed(SEED)
    picked = random.sample(codes, min(SAMPLE, len(codes)))
    for c in MUST_INCLUDE:
        if c in codes and c not in picked:
            picked.append(c)
    print(f"[probe] pool={len(codes)} sample={len(picked)}", flush=True)

    rows = []
    t0 = time.time()
    for i, code in enumerate(picked, 1):
        try:
            h = fetch_history(code, 120, 0.1)
            if h.empty:
                continue
            left = evaluate_oversold_rebound(code, names.get(code, "?"), "-", h)
            m = right_side_metrics(h)
            if m is None:
                continue
            m.update(code=code, name=names.get(code, "?"),
                     left_match=bool(left.get("is_match")), close=left.get("close"))
            rows.append(m)
        except Exception as exc:
            print(f"WARN {code}: {exc}", file=sys.stderr)
        if i % 50 == 0:
            print(f"[probe] {i}/{len(picked)} elapsed={time.time()-t0:.0f}s", flush=True)

    df = pd.DataFrame(rows)
    n = len(df)
    print(f"\n[probe] evaluated={n} (elapsed {time.time()-t0:.0f}s)")
    if n == 0:
        return 1

    left_n = int(df["left_match"].sum())
    print(f"[left ] matches={left_n}  rate={left_n/n*100:.2f}%  -> est. market-wide ~{left_n/n*5000:.0f}")

    print("\n[right] threshold sweep (max_days / min_surge / max_rebound):")
    print(f"{'days':>5}{'surge':>7}{'reb%':>7}{'hit':>6}{'rate%':>8}{'est/5000':>10}{'new(excl左侧)':>14}")
    for max_days in (3, 5, 8):
        for min_surge in (1.5, 2.0, 2.5, 3.0):
            for max_rebound in (40.0, 50.0):
                hits = df.apply(lambda r: right_side_match(r, max_days, min_surge, max_rebound), axis=1)
                k = int(hits.sum())
                new = int((hits & ~df["left_match"]).sum())
                print(f"{max_days:>5}{min_surge:>7.1f}{max_rebound:>7.0f}{k:>6}"
                      f"{k/n*100:>8.2f}{k/n*5000:>10.0f}{new/n*5000:>14.0f}")

    print("\n[check] the two stocks in question:")
    for c in MUST_INCLUDE:
        sub = df[df["code"] == c]
        if sub.empty:
            print(f"   {c}: not evaluated")
            continue
        r = sub.iloc[0]
        print(f"   {c} {r['name']}: days_above_ma30={r['days_above_ma30']} "
              f"vol_surge={r['vol_surge']:.2f} ma5>ma13={r['ma5_gt_ma13']} "
              f"rebound={r['rebound_pct']:.1f}% dd={r['drawdown_pct']:.1f}% "
              f"not_broken={r['not_broken']} left={r['left_match']} "
              f"-> right(5/2.0/50)={right_side_match(r, 5, 2.0, 50.0)}")

    base = df.apply(lambda r: right_side_match(r, 5, 2.0, 50.0), axis=1)
    print("\n[right] sample hits at (5 / 2.0x / 50%):")
    for _, r in df[base].iterrows():
        print(f"   {r['code']} {r['name']:<8} close={r['close']} "
              f"days={r['days_above_ma30']} surge={r['vol_surge']:.1f} "
              f"reb={r['rebound_pct']:.0f}% dd={r['drawdown_pct']:.0f}% left={r['left_match']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
