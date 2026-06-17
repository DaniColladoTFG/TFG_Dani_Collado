# DEPRECATED — use abir_fase11_optimizer.py instead
from __future__ import annotations

import json
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from typing import Protocol

import pandas as pd


@dataclass(frozen=True)
class DataConfig:
    csv_path: Path
    date_col: str = "date"
    open_col: str = "open"
    high_col: str = "high"
    low_col: str = "low"
    close_col: str = "close"


@dataclass(frozen=True)
class ABIRParams:
    adr_window: int = 14
    atr_window: int = 14
    bb_window: int = 20
    bb_std: float = 2.0
    atr_expansion_factor: float = 1.1
    tp_sl_adr_fraction: float = 0.45


@dataclass(frozen=True)
class PortfolioConfig:
    initial_capital: float = 10_000.0
    allocation_per_trade: float = 0.05
    fixed_cost_per_trade: float = 0.0


class ExitReason(str, Enum):
    TP = "TP"
    SL = "SL"
    TIME_CLOSE = "TIME_CLOSE"


class MarketDataLoader(Protocol):
    def load(self) -> pd.DataFrame:
        ...


class FeatureCalculator(Protocol):
    def compute(self, df: pd.DataFrame) -> pd.DataFrame:
        ...


class SignalGenerator(Protocol):
    def generate(self, df: pd.DataFrame) -> pd.DataFrame:
        ...


class ExecutionEngine(Protocol):
    name: str

    def run(self, signal_df: pd.DataFrame, portfolio_cfg: PortfolioConfig) -> "EngineRunResult":
        ...


@dataclass
class EngineRunResult:
    trades: pd.DataFrame
    summary: dict


class CSVMT5DailyLoader:
    """
    Capa 1: Ingesta y normalizacion de OHLC D1.
    Soporta formato MT5 tipico con columnas <DATE>, <OPEN>, etc.
    """

    COLUMN_MAP = {
        "<DATE>": "date",
        "<OPEN>": "open",
        "<HIGH>": "high",
        "<LOW>": "low",
        "<CLOSE>": "close",
        "<TICKVOL>": "tickvol",
        "<VOL>": "vol",
        "<SPREAD>": "spread",
    }

    def __init__(self, cfg: DataConfig) -> None:
        self.cfg = cfg

    def load(self) -> pd.DataFrame:
        raw = pd.read_csv(self.cfg.csv_path, sep="\t")
        if raw.shape[1] == 1:
            raw = pd.read_csv(self.cfg.csv_path)

        raw = raw.rename(columns=self.COLUMN_MAP)
        expected = {"date", "open", "high", "low", "close"}
        missing = expected.difference(raw.columns)
        if missing:
            raise ValueError(f"Faltan columnas OHLC requeridas: {sorted(missing)}")

        raw["date"] = pd.to_datetime(raw["date"], format="%Y.%m.%d", errors="coerce")
        if raw["date"].isna().any():
            raw["date"] = pd.to_datetime(raw["date"], errors="coerce")

        for col in ("open", "high", "low", "close"):
            raw[col] = pd.to_numeric(raw[col], errors="coerce")

        df = (
            raw.dropna(subset=["date", "open", "high", "low", "close"])
            .sort_values("date")
            .drop_duplicates(subset=["date"], keep="last")
            .reset_index(drop=True)
        )
        return df


class ABIRFeatureCalculator:
    """
    Capa 2: Features tecnicas vectoriales (ADR, ATR, BB lower).
    """

    def __init__(self, params: ABIRParams) -> None:
        self.params = params

    def compute(self, df: pd.DataFrame) -> pd.DataFrame:
        out = df.copy()

        out["daily_range"] = out["high"] - out["low"]
        out["adr14"] = out["daily_range"].rolling(self.params.adr_window).mean()

        prev_close = out["close"].shift(1)
        tr_hl = out["high"] - out["low"]
        tr_hpc = (out["high"] - prev_close).abs()
        tr_lpc = (out["low"] - prev_close).abs()
        out["true_range"] = pd.concat([tr_hl, tr_hpc, tr_lpc], axis=1).max(axis=1)
        out["atr14"] = out["true_range"].rolling(self.params.atr_window).mean()

        out["bb_mid"] = out["close"].rolling(self.params.bb_window).mean()
        out["bb_std"] = out["close"].rolling(self.params.bb_window).std(ddof=0)
        out["bb_lower"] = out["bb_mid"] - self.params.bb_std * out["bb_std"]

        return out


class ABIRSignalGenerator:
    """
    Capa 3: Senal de entrada ABIR sin lookahead.
    """

    def __init__(self, params: ABIRParams) -> None:
        self.params = params

    def generate(self, df: pd.DataFrame) -> pd.DataFrame:
        out = df.copy()
        adr_prev = out["adr14"].shift(1)
        atr_prev = out["atr14"].shift(1)
        bb_lower_prev = out["bb_lower"].shift(1)
        close_prev = out["close"].shift(1)

        out["close_below_bb_prev"] = close_prev < bb_lower_prev
        out["range_expanded_prev"] = adr_prev > (self.params.atr_expansion_factor * atr_prev)
        out["enter_long"] = out["close_below_bb_prev"] & out["range_expanded_prev"]

        out["entry_price"] = out["open"]
        out["risk_distance"] = self.params.tp_sl_adr_fraction * adr_prev
        out["tp_price"] = out["entry_price"] + out["risk_distance"]
        out["sl_price"] = out["entry_price"] - out["risk_distance"]

        # Solo hay trade cuando hay senal y niveles validos.
        out["trade_eligible"] = out["enter_long"] & out["risk_distance"].notna() & (out["risk_distance"] > 0)
        return out


class ABIRBaseExecutionEngine:
    """
    Capa 4/5: motor de ejecucion diario.
    La unica diferencia modular es la prioridad en velas ambiguas.
    """

    name: str = "base"
    priority: tuple[ExitReason, ExitReason] = (ExitReason.TP, ExitReason.SL)

    def _resolve_exit(self, row: pd.Series) -> tuple[ExitReason, float, bool, bool]:
        tp = float(row["tp_price"])
        sl = float(row["sl_price"])
        close = float(row["close"])
        high = float(row["high"])
        low = float(row["low"])

        hit_tp = high >= tp
        hit_sl = low <= sl

        if hit_tp and hit_sl:
            first = self.priority[0]
            if first == ExitReason.TP:
                return ExitReason.TP, tp, hit_tp, hit_sl
            return ExitReason.SL, sl, hit_tp, hit_sl

        if hit_tp:
            return ExitReason.TP, tp, hit_tp, hit_sl
        if hit_sl:
            return ExitReason.SL, sl, hit_tp, hit_sl
        return ExitReason.TIME_CLOSE, close, hit_tp, hit_sl

    def run(self, signal_df: pd.DataFrame, portfolio_cfg: PortfolioConfig) -> EngineRunResult:
        trades: list[dict] = []
        equity = portfolio_cfg.initial_capital

        candidates = signal_df.loc[signal_df["trade_eligible"]].copy()
        for _, row in candidates.iterrows():
            entry = float(row["entry_price"])
            tp = float(row["tp_price"])
            sl = float(row["sl_price"])

            exit_reason, exit_price, hit_tp, hit_sl = self._resolve_exit(row)
            ambiguous = bool(hit_tp and hit_sl)

            notional = equity * portfolio_cfg.allocation_per_trade
            units = 0.0 if entry <= 0 else notional / entry
            gross_pnl = (exit_price - entry) * units
            net_pnl = gross_pnl - portfolio_cfg.fixed_cost_per_trade
            equity_after = equity + net_pnl

            risk_per_unit = entry - sl
            if risk_per_unit > 0:
                r_multiple = (exit_price - entry) / risk_per_unit
            else:
                r_multiple = 0.0

            trades.append(
                {
                    "date": row["date"],
                    "engine": self.name,
                    "entry_price": entry,
                    "tp_price": tp,
                    "sl_price": sl,
                    "day_high": float(row["high"]),
                    "day_low": float(row["low"]),
                    "day_close": float(row["close"]),
                    "hit_tp": hit_tp,
                    "hit_sl": hit_sl,
                    "ambiguous_trade": ambiguous,
                    "exit_reason": exit_reason.value,
                    "exit_price": exit_price,
                    "notional": notional,
                    "gross_pnl": gross_pnl,
                    "net_pnl": net_pnl,
                    "r_multiple": r_multiple,
                    "equity_before": equity,
                    "equity_after": equity_after,
                }
            )
            equity = equity_after

        trades_df = pd.DataFrame(trades)
        summary = self._build_summary(trades_df, portfolio_cfg.initial_capital, equity)
        return EngineRunResult(trades=trades_df, summary=summary)

    @staticmethod
    def _build_summary(trades_df: pd.DataFrame, initial_capital: float, final_equity: float) -> dict:
        if trades_df.empty:
            return {
                "trades": 0,
                "wins": 0,
                "losses": 0,
                "win_rate": 0.0,
                "ambiguous_trades": 0,
                "ambiguous_ratio": 0.0,
                "pnl_total": 0.0,
                "equity_initial": initial_capital,
                "equity_final": final_equity,
                "return_pct": 0.0,
                "avg_r_multiple": 0.0,
            }

        wins = int((trades_df["net_pnl"] > 0).sum())
        losses = int((trades_df["net_pnl"] < 0).sum())
        trades = len(trades_df)
        ambiguous = int(trades_df["ambiguous_trade"].sum())
        pnl_total = float(trades_df["net_pnl"].sum())
        return_pct = 0.0 if initial_capital == 0 else ((final_equity / initial_capital) - 1.0) * 100.0
        avg_r = float(trades_df["r_multiple"].mean())

        return {
            "trades": trades,
            "wins": wins,
            "losses": losses,
            "win_rate": wins / trades,
            "ambiguous_trades": ambiguous,
            "ambiguous_ratio": ambiguous / trades,
            "pnl_total": pnl_total,
            "equity_initial": initial_capital,
            "equity_final": final_equity,
            "return_pct": return_pct,
            "avg_r_multiple": avg_r,
        }


class OptimisticExecutionEngine(ABIRBaseExecutionEngine):
    name = "optimistic_high_first"
    priority = (ExitReason.TP, ExitReason.SL)


class PessimisticExecutionEngine(ABIRBaseExecutionEngine):
    name = "pessimistic_low_first"
    priority = (ExitReason.SL, ExitReason.TP)


class ExecutionEngineFactory:
    REGISTRY = {
        "optimistic": OptimisticExecutionEngine,
        "pessimistic": PessimisticExecutionEngine,
    }

    @classmethod
    def create(cls, mode: str) -> ABIRBaseExecutionEngine:
        if mode not in cls.REGISTRY:
            allowed = ", ".join(sorted(cls.REGISTRY))
            raise ValueError(f"Modo de motor no soportado '{mode}'. Opciones: {allowed}")
        return cls.REGISTRY[mode]()


class ABIRComparator:
    @staticmethod
    def compare(results: dict[str, EngineRunResult]) -> pd.DataFrame:
        rows = []
        for engine_name, result in results.items():
            row = {"engine": engine_name}
            row.update(result.summary)
            rows.append(row)

        comp = pd.DataFrame(rows).sort_values("engine").reset_index(drop=True)
        if {"optimistic_high_first", "pessimistic_low_first"}.issubset(set(comp["engine"])):
            opt = comp.loc[comp["engine"] == "optimistic_high_first"].iloc[0]
            pes = comp.loc[comp["engine"] == "pessimistic_low_first"].iloc[0]
            delta_wr = float(opt["win_rate"] - pes["win_rate"])
            delta_pnl = float(opt["pnl_total"] - pes["pnl_total"])
            delta_return = float(opt["return_pct"] - pes["return_pct"])
            comp["delta_vs_pessimistic"] = 0.0
            comp.loc[comp["engine"] == "optimistic_high_first", "delta_vs_pessimistic"] = 1.0

            diagnostics = pd.DataFrame(
                [
                    {
                        "engine": "diagnostics",
                        "trades": int(opt["trades"]),
                        "wins": int(opt["wins"] - pes["wins"]),
                        "losses": int(opt["losses"] - pes["losses"]),
                        "win_rate": delta_wr,
                        "ambiguous_trades": int(opt["ambiguous_trades"]),
                        "ambiguous_ratio": float(opt["ambiguous_ratio"]),
                        "pnl_total": delta_pnl,
                        "equity_initial": float(opt["equity_initial"]),
                        "equity_final": float(opt["equity_final"] - pes["equity_final"]),
                        "return_pct": delta_return,
                        "avg_r_multiple": float(opt["avg_r_multiple"] - pes["avg_r_multiple"]),
                        "delta_vs_pessimistic": 0.0,
                    }
                ]
            )
            comp = pd.concat([comp, diagnostics], ignore_index=True)
        return comp


def build_signal_diagnostics(signal_df: pd.DataFrame) -> dict:
    close_below = int(signal_df["close_below_bb_prev"].fillna(False).sum())
    range_expanded = int(signal_df["range_expanded_prev"].fillna(False).sum())
    enter_long = int(signal_df["enter_long"].fillna(False).sum())
    eligible = int(signal_df["trade_eligible"].fillna(False).sum())
    total_rows = int(len(signal_df))

    diagnostics = {
        "rows_total": total_rows,
        "close_below_bb_prev_count": close_below,
        "range_expanded_prev_count": range_expanded,
        "enter_long_count": enter_long,
        "trade_eligible_count": eligible,
        "close_below_ratio": 0.0 if total_rows == 0 else close_below / total_rows,
        "range_expanded_ratio": 0.0 if total_rows == 0 else range_expanded / total_rows,
        "enter_long_ratio": 0.0 if total_rows == 0 else enter_long / total_rows,
    }

    if range_expanded == 0:
        diagnostics["warning"] = (
            "No existen filas con ADR14 > 1.1*ATR14. Esto puede ocurrir porque ATR14 usa True Range "
            "y suele ser >= ADR14 por construccion."
        )
    return diagnostics


@dataclass
class ABIRPipeline:
    loader: MarketDataLoader
    feature_calculator: FeatureCalculator
    signal_generator: SignalGenerator
    engines: list[ExecutionEngine]
    portfolio_cfg: PortfolioConfig

    def run(self) -> tuple[pd.DataFrame, pd.DataFrame, dict[str, EngineRunResult], pd.DataFrame]:
        df = self.loader.load()
        feature_df = self.feature_calculator.compute(df)
        signal_df = self.signal_generator.generate(feature_df)

        results: dict[str, EngineRunResult] = {}
        for engine in self.engines:
            results[engine.name] = engine.run(signal_df, self.portfolio_cfg)

        comparison = ABIRComparator.compare(results)
        return feature_df, signal_df, results, comparison


def build_default_pipeline(data_path: Path) -> ABIRPipeline:
    params = ABIRParams()
    data_cfg = DataConfig(csv_path=data_path)
    loader = CSVMT5DailyLoader(data_cfg)
    feature_calc = ABIRFeatureCalculator(params)
    signal_gen = ABIRSignalGenerator(params)
    engines = [
        ExecutionEngineFactory.create("optimistic"),
        ExecutionEngineFactory.create("pessimistic"),
    ]
    portfolio_cfg = PortfolioConfig()
    return ABIRPipeline(
        loader=loader,
        feature_calculator=feature_calc,
        signal_generator=signal_gen,
        engines=engines,
        portfolio_cfg=portfolio_cfg,
    )


def export_results(
    out_dir: Path,
    feature_df: pd.DataFrame,
    signal_df: pd.DataFrame,
    results: dict[str, EngineRunResult],
    comparison: pd.DataFrame,
    signal_diagnostics: dict,
) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)

    feature_df.to_csv(out_dir / "abir_features.csv", index=False)
    signal_df.to_csv(out_dir / "abir_signals.csv", index=False)

    summary_payload = {}
    for engine_name, result in results.items():
        result.trades.to_csv(out_dir / f"abir_trades_{engine_name}.csv", index=False)
        summary_payload[engine_name] = result.summary

    comparison.to_csv(out_dir / "abir_engine_comparison.csv", index=False)
    with (out_dir / "abir_summary.json").open("w", encoding="utf-8") as f:
        json.dump(summary_payload, f, ensure_ascii=True, indent=2, default=str)
    with (out_dir / "abir_signal_diagnostics.json").open("w", encoding="utf-8") as f:
        json.dump(signal_diagnostics, f, ensure_ascii=True, indent=2, default=str)


def main() -> None:
    root_dir = Path(__file__).resolve().parents[1]
    data_path = root_dir / "XAUUSD_Daily_2016_2026.csv"
    out_dir = root_dir / "Estrategia_2" / "fase1_outputs"

    pipeline = build_default_pipeline(data_path)
    feature_df, signal_df, results, comparison = pipeline.run()
    signal_diagnostics = build_signal_diagnostics(signal_df)
    export_results(out_dir, feature_df, signal_df, results, comparison, signal_diagnostics)

    print("=== ABIR Fase 1 completada ===")
    print(f"CSV de entrada: {data_path}")
    print(f"Carpeta de salida: {out_dir}")
    print(comparison.to_string(index=False))
    print("Signal diagnostics:")
    print(json.dumps(signal_diagnostics, ensure_ascii=True, indent=2, default=str))

    for engine_name, result in results.items():
        payload = {"engine": engine_name, **result.summary}
        print(json.dumps(payload, ensure_ascii=True, indent=2, default=str))


if __name__ == "__main__":
    main()
