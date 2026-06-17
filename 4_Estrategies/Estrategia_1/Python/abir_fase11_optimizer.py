from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import pandas as pd


ROOT_DIR = Path(__file__).resolve().parents[1]
DATA_PATH = ROOT_DIR / "XAUUSD_Daily_2016_2026.csv"
OUT_DIR = ROOT_DIR / "Estrategia_2" / "fase11_outputs"

INITIAL_CAPITAL = 10_000.0
ALLOCATION_PER_TRADE = 0.05
MIN_TRADES = 100


@dataclass(frozen=True)
class ComboResult:
    bb_window: int
    bb_std: float
    tp_mult: float
    sl_mult: float
    vol_filter: str
    vol_window: int
    vol_param: float
    trades: int
    ambiguous_trades: int
    ambiguous_ratio: float
    win_rate_opt: float
    win_rate_pes: float
    delta_win_rate: float
    pnl_opt: float
    pnl_pes: float
    delta_pnl: float
    return_opt_pct: float
    return_pes_pct: float
    delta_return_pct: float


def load_daily_csv(path: Path) -> pd.DataFrame:
    df = pd.read_csv(path, sep="\t")
    if df.shape[1] == 1:
        df = pd.read_csv(path)

    df = df.rename(
        columns={
            "<DATE>": "date",
            "<OPEN>": "open",
            "<HIGH>": "high",
            "<LOW>": "low",
            "<CLOSE>": "close",
            "<TICKVOL>": "tickvol",
            "<VOL>": "vol",
            "<SPREAD>": "spread",
        }
    )
    for required in ("date", "open", "high", "low", "close"):
        if required not in df.columns:
            raise ValueError(f"Columna requerida ausente: {required}")

    df["date"] = pd.to_datetime(df["date"], format="%Y.%m.%d", errors="coerce")
    if df["date"].isna().any():
        df["date"] = pd.to_datetime(df["date"], errors="coerce")

    for c in ("open", "high", "low", "close"):
        df[c] = pd.to_numeric(df[c], errors="coerce")

    return (
        df.dropna(subset=["date", "open", "high", "low", "close"])
        .sort_values("date")
        .drop_duplicates(subset=["date"], keep="last")
        .reset_index(drop=True)
    )


def precompute_features(df: pd.DataFrame) -> tuple[pd.DataFrame, dict[tuple[int, float], pd.Series], dict[tuple[str, int, float], pd.Series]]:
    work = df.copy()
    work["daily_range"] = work["high"] - work["low"]
    work["adr14"] = work["daily_range"].rolling(14).mean()
    work["adr14_prev"] = work["adr14"].shift(1)
    work["close_prev"] = work["close"].shift(1)
    work["daily_range_prev"] = work["daily_range"].shift(1)

    bb_windows = [14, 20, 26, 30]
    bb_stds = [1.5, 1.8, 2.0, 2.2, 2.5]
    bb_cache: dict[tuple[int, float], pd.Series] = {}
    for w in bb_windows:
        mean_w = work["close"].rolling(w).mean()
        std_w = work["close"].rolling(w).std(ddof=0)
        for s in bb_stds:
            bb_cache[(w, s)] = (mean_w - s * std_w).shift(1)

    vol_cache: dict[tuple[str, int, float], pd.Series] = {}
    # Filtro 1: ADR14 actual vs media movil del ADR14
    adr_ma_windows = [10, 14, 20, 30]
    adr_ma_k = [0.98, 1.00, 1.02, 1.05, 1.08, 1.10]
    for w in adr_ma_windows:
        adr_ma = work["adr14"].rolling(w).mean().shift(1)
        for k in adr_ma_k:
            vol_cache[("adr_vs_adr_ma", w, float(k))] = work["adr14_prev"] > (k * adr_ma)

    # Filtro 2: rango del dia previo por encima de percentil movil
    q_windows = [10, 14, 20, 30]
    qs = [0.60, 0.65, 0.70, 0.75, 0.80, 0.85]
    for w in q_windows:
        q_series = work["daily_range"].rolling(w).quantile
        for q in qs:
            threshold = q_series(q).shift(1)
            vol_cache[("range_vs_quantile", w, float(q))] = work["daily_range_prev"] > threshold

    return work, bb_cache, vol_cache


def evaluate_combo(
    work: pd.DataFrame,
    bb_prev: pd.Series,
    vol_mask: pd.Series,
    tp_mult: float,
    sl_mult: float,
) -> ComboResult | None:
    signal = (work["close_prev"] < bb_prev) & vol_mask & work["adr14_prev"].notna()
    signal &= work["adr14_prev"] > 0

    if signal.sum() < MIN_TRADES:
        return None

    frame = work.loc[signal, ["date", "open", "high", "low", "close", "adr14_prev"]].copy()
    frame["entry"] = frame["open"]
    frame["tp"] = frame["entry"] + tp_mult * frame["adr14_prev"]
    frame["sl"] = frame["entry"] - sl_mult * frame["adr14_prev"]

    hit_tp = frame["high"] >= frame["tp"]
    hit_sl = frame["low"] <= frame["sl"]
    ambiguous = hit_tp & hit_sl

    # Motor optimista: TP primero en ambiguas
    exit_opt = np.where(hit_tp, frame["tp"], np.where(hit_sl, frame["sl"], frame["close"]))
    # Motor pesimista: SL primero en ambiguas
    exit_pes = np.where(hit_sl, frame["sl"], np.where(hit_tp, frame["tp"], frame["close"]))

    notional = INITIAL_CAPITAL * ALLOCATION_PER_TRADE
    units = np.where(frame["entry"] > 0, notional / frame["entry"], 0.0)

    pnl_opt = (exit_opt - frame["entry"].to_numpy()) * units
    pnl_pes = (exit_pes - frame["entry"].to_numpy()) * units

    wins_opt = int((pnl_opt > 0).sum())
    wins_pes = int((pnl_pes > 0).sum())
    trades = len(frame)
    ambiguous_trades = int(ambiguous.sum())

    total_pnl_opt = float(pnl_opt.sum())
    total_pnl_pes = float(pnl_pes.sum())

    wr_opt = wins_opt / trades
    wr_pes = wins_pes / trades
    delta_wr = wr_opt - wr_pes
    delta_pnl = total_pnl_opt - total_pnl_pes
    ret_opt = (total_pnl_opt / INITIAL_CAPITAL) * 100.0
    ret_pes = (total_pnl_pes / INITIAL_CAPITAL) * 100.0

    return ComboResult(
        bb_window=0,
        bb_std=0.0,
        tp_mult=float(tp_mult),
        sl_mult=float(sl_mult),
        vol_filter="",
        vol_window=0,
        vol_param=0.0,
        trades=trades,
        ambiguous_trades=ambiguous_trades,
        ambiguous_ratio=ambiguous_trades / trades,
        win_rate_opt=wr_opt,
        win_rate_pes=wr_pes,
        delta_win_rate=delta_wr,
        pnl_opt=total_pnl_opt,
        pnl_pes=total_pnl_pes,
        delta_pnl=delta_pnl,
        return_opt_pct=ret_opt,
        return_pes_pct=ret_pes,
        delta_return_pct=ret_opt - ret_pes,
    )


def run_optimization() -> pd.DataFrame:
    df = load_daily_csv(DATA_PATH)
    work, bb_cache, vol_cache = precompute_features(df)

    tp_values = np.round(np.arange(0.20, 0.65, 0.05), 2)
    sl_values = np.round(np.arange(0.20, 0.65, 0.05), 2)

    rows: list[dict] = []
    for (bb_window, bb_std), bb_prev in bb_cache.items():
        for (vol_filter, vol_window, vol_param), vol_mask in vol_cache.items():
            for tp_mult in tp_values:
                for sl_mult in sl_values:
                    result = evaluate_combo(work, bb_prev, vol_mask, float(tp_mult), float(sl_mult))
                    if result is None:
                        continue

                    payload = result.__dict__.copy()
                    payload["bb_window"] = bb_window
                    payload["bb_std"] = float(bb_std)
                    payload["vol_filter"] = vol_filter
                    payload["vol_window"] = int(vol_window)
                    payload["vol_param"] = float(vol_param)
                    payload["score_primary"] = payload["delta_win_rate"]
                    payload["score_secondary"] = payload["delta_return_pct"]
                    payload["score_tertiary"] = payload["ambiguous_ratio"]
                    rows.append(payload)

    if not rows:
        raise RuntimeError("No se encontraron combinaciones con el minimo de trades requerido.")

    results = pd.DataFrame(rows)
    results = results.sort_values(
        by=["score_primary", "score_secondary", "score_tertiary", "trades"],
        ascending=[False, False, False, False],
    ).reset_index(drop=True)
    return results


def build_report(best: pd.Series, total_tested: int) -> dict:
    return {
        "objective": "max_delta_deception",
        "tested_valid_combinations": int(total_tested),
        "min_trades_constraint": int(MIN_TRADES),
        "best_params": {
            "bb_window": int(best["bb_window"]),
            "bb_std": float(best["bb_std"]),
            "tp_mult_adr": float(best["tp_mult"]),
            "sl_mult_adr": float(best["sl_mult"]),
            "vol_filter": str(best["vol_filter"]),
            "vol_window": int(best["vol_window"]),
            "vol_param": float(best["vol_param"]),
        },
        "best_metrics": {
            "trades": int(best["trades"]),
            "ambiguous_trades": int(best["ambiguous_trades"]),
            "ambiguous_ratio": float(best["ambiguous_ratio"]),
            "win_rate_optimistic": float(best["win_rate_opt"]),
            "win_rate_pessimistic": float(best["win_rate_pes"]),
            "delta_win_rate": float(best["delta_win_rate"]),
            "pnl_optimistic": float(best["pnl_opt"]),
            "pnl_pessimistic": float(best["pnl_pes"]),
            "delta_pnl": float(best["delta_pnl"]),
            "return_optimistic_pct": float(best["return_opt_pct"]),
            "return_pessimistic_pct": float(best["return_pes_pct"]),
            "delta_return_pct": float(best["delta_return_pct"]),
        },
    }


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    results = run_optimization()
    best = results.iloc[0]
    report = build_report(best, total_tested=len(results))

    results.to_csv(OUT_DIR / "abir_fase11_grid_results.csv", index=False)
    results.head(100).to_csv(OUT_DIR / "abir_fase11_top100.csv", index=False)
    with (OUT_DIR / "abir_fase11_best_report.json").open("w", encoding="utf-8") as f:
        json.dump(report, f, ensure_ascii=True, indent=2)

    print("=== ABIR Fase 1.1 Optimization Complete ===")
    print(f"Input CSV: {DATA_PATH}")
    print(f"Output dir: {OUT_DIR}")
    print(f"Valid combos tested: {len(results)}")
    print(results.head(10).to_string(index=False))
    print(json.dumps(report, ensure_ascii=True, indent=2))


if __name__ == "__main__":
    main()
