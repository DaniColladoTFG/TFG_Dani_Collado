from __future__ import annotations

import json
from pathlib import Path

import matplotlib.pyplot as plt
import pandas as pd
import seaborn as sns


ROOT_DIR = Path(__file__).resolve().parents[1]
DATA_PATH = ROOT_DIR / "XAUUSD_Daily_2016_2026.csv"
BEST_PATH = ROOT_DIR / "Estrategia_2" / "fase11_outputs" / "abir_fase11_best_report.json"
OUT_DIR = ROOT_DIR / "Estrategia_2" / "fase11_plots"

INITIAL_CAPITAL = 10_000.0
ALLOCATION_PER_TRADE = 0.05


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
        }
    )
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


def compute_feature_frame(df: pd.DataFrame, bb_window: int, bb_std: float) -> pd.DataFrame:
    out = df.copy()
    out["daily_range"] = out["high"] - out["low"]
    out["adr14"] = out["daily_range"].rolling(14).mean()
    out["adr14_prev"] = out["adr14"].shift(1)
    out["close_prev"] = out["close"].shift(1)

    bb_mid = out["close"].rolling(bb_window).mean()
    bb_sigma = out["close"].rolling(bb_window).std(ddof=0)
    out["bb_lower_prev"] = (bb_mid - bb_std * bb_sigma).shift(1)

    return out


def build_vol_filter(df: pd.DataFrame, filter_name: str, vol_window: int, vol_param: float) -> pd.Series:
    if filter_name == "adr_vs_adr_ma":
        adr_ma = df["adr14"].rolling(vol_window).mean().shift(1)
        return df["adr14_prev"] > (vol_param * adr_ma)
    if filter_name == "range_vs_quantile":
        threshold = df["daily_range"].rolling(vol_window).quantile(vol_param).shift(1)
        return df["daily_range"].shift(1) > threshold
    raise ValueError(f"Filtro de volatilidad no soportado: {filter_name}")


def build_trade_log(
    df: pd.DataFrame,
    tp_mult: float,
    sl_mult: float,
    vol_mask: pd.Series,
) -> pd.DataFrame:
    signal = (df["close_prev"] < df["bb_lower_prev"]) & vol_mask & df["adr14_prev"].notna() & (df["adr14_prev"] > 0)
    trades = df.loc[signal, ["date", "open", "high", "low", "close", "adr14_prev"]].copy()

    trades["entry"] = trades["open"]
    trades["tp"] = trades["entry"] + tp_mult * trades["adr14_prev"]
    trades["sl"] = trades["entry"] - sl_mult * trades["adr14_prev"]
    trades["hit_tp"] = trades["high"] >= trades["tp"]
    trades["hit_sl"] = trades["low"] <= trades["sl"]
    trades["ambiguous_trade"] = trades["hit_tp"] & trades["hit_sl"]

    trades["exit_opt"] = trades["close"]
    trades.loc[trades["hit_sl"], "exit_opt"] = trades.loc[trades["hit_sl"], "sl"]
    trades.loc[trades["hit_tp"], "exit_opt"] = trades.loc[trades["hit_tp"], "tp"]

    trades["exit_pes"] = trades["close"]
    trades.loc[trades["hit_tp"], "exit_pes"] = trades.loc[trades["hit_tp"], "tp"]
    trades.loc[trades["hit_sl"], "exit_pes"] = trades.loc[trades["hit_sl"], "sl"]

    notional = INITIAL_CAPITAL * ALLOCATION_PER_TRADE
    trades["units"] = notional / trades["entry"]
    trades["pnl_opt"] = (trades["exit_opt"] - trades["entry"]) * trades["units"]
    trades["pnl_pes"] = (trades["exit_pes"] - trades["entry"]) * trades["units"]
    trades["equity_opt"] = INITIAL_CAPITAL + trades["pnl_opt"].cumsum()
    trades["equity_pes"] = INITIAL_CAPITAL + trades["pnl_pes"].cumsum()
    return trades.reset_index(drop=True)


def plot_equity_curve(trades: pd.DataFrame, out_dir: Path) -> None:
    fig, ax = plt.subplots(figsize=(12, 6), dpi=300)
    ax.plot(trades["date"], trades["equity_opt"], label="Motor Optimista (High-first)", linewidth=2.2)
    ax.plot(trades["date"], trades["equity_pes"], label="Motor Pesimista (Low-first)", linewidth=2.2)
    ax.axhline(INITIAL_CAPITAL, color="black", linestyle="--", linewidth=1.0, alpha=0.6, label="Capital inicial")

    ax.set_title("ABIR - Curva de Capital: Optimista vs Pesimista", fontsize=13, fontweight="bold")
    ax.set_xlabel("Fecha")
    ax.set_ylabel("Equity")
    ax.legend(loc="best", frameon=True)
    ax.grid(alpha=0.25)
    fig.tight_layout()
    fig.savefig(out_dir / "equity_curve_optimistic_vs_pessimistic.png", dpi=400, bbox_inches="tight")
    plt.close(fig)


def plot_ambiguity_histogram(trades: pd.DataFrame, out_dir: Path) -> None:
    fig, ax = plt.subplots(figsize=(10, 6), dpi=300)
    data = trades["ambiguous_trade"].astype(int)
    sns.histplot(data=data, bins=[-0.5, 0.5, 1.5], discrete=True, shrink=0.6, ax=ax)

    total = len(trades)
    ambiguous = int(trades["ambiguous_trade"].sum())
    non_ambiguous = total - ambiguous
    ratio = 0.0 if total == 0 else ambiguous / total

    ax.set_xticks([0, 1])
    ax.set_xticklabels(["No ambiguo", "Ambiguo"])
    ax.set_title("ABIR - Histograma de Ambiguedad de Trades", fontsize=13, fontweight="bold")
    ax.set_xlabel("Tipo de trade")
    ax.set_ylabel("Frecuencia")
    ax.grid(axis="y", alpha=0.25)

    ax.text(
        0.02,
        0.95,
        f"Total trades: {total}\nAmbiguos: {ambiguous} ({ratio:.2%})\nNo ambiguos: {non_ambiguous}",
        transform=ax.transAxes,
        verticalalignment="top",
        bbox={"boxstyle": "round,pad=0.35", "facecolor": "white", "alpha": 0.9, "edgecolor": "gray"},
    )
    fig.tight_layout()
    fig.savefig(out_dir / "ambiguity_histogram.png", dpi=400, bbox_inches="tight")
    plt.close(fig)


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    sns.set_theme(style="whitegrid", context="talk")

    with BEST_PATH.open("r", encoding="utf-8") as f:
        best_report = json.load(f)
    p = best_report["best_params"]

    df = load_daily_csv(DATA_PATH)
    feat = compute_feature_frame(df, bb_window=int(p["bb_window"]), bb_std=float(p["bb_std"]))
    vol_mask = build_vol_filter(
        feat,
        filter_name=str(p["vol_filter"]),
        vol_window=int(p["vol_window"]),
        vol_param=float(p["vol_param"]),
    )
    trades = build_trade_log(
        feat,
        tp_mult=float(p["tp_mult_adr"]),
        sl_mult=float(p["sl_mult_adr"]),
        vol_mask=vol_mask,
    )

    trades.to_csv(OUT_DIR / "trades_best_config.csv", index=False)
    plot_equity_curve(trades, OUT_DIR)
    plot_ambiguity_histogram(trades, OUT_DIR)

    print("=== ABIR Fase 1.1 plots generated ===")
    print(f"Output dir: {OUT_DIR}")
    print(f"Trades in best config: {len(trades)}")
    print(f"Ambiguous trades: {int(trades['ambiguous_trade'].sum())}")


if __name__ == "__main__":
    main()
