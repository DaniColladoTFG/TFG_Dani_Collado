# Cierre practico Estrategia 2 - ZScore + regimen D1 (v1.14)

Fecha documento: 2026-06-04
Activo: XAUUSD_TFG | TF: D1 | Cuenta: 10 000 EUR | Apalancamiento 1:20
EA backtests: Estrategia2 - Dependent_Regim_Mercat_2.ex5 (v1.14; fuente mq5 Estr2 - Dependent_Regim_Mercat_2.mq5)
MagicNumber: 543210 (protocolo y HTML)

---

## 1. Informes HTML

Ruta: `Results_Reports/`

| Preset | Ventana | Archivo |
|--------|---------|---------|
| A | IS | ReportE2_A_IS-2016-2023.html |
| A | OOS | ReportE2_A_OS-2023-2026.html |
| A | FULL | ReportE2_A-2016-2026.html |
| B | IS | ReportE2_B_IS-2016-2023.html |
| B | OOS | ReportE2_B_OS-2023-2026.html |
| B | FULL | ReportE2_B-2016-2026.html |

Calidad historial (todos): 100% ticks reales.
Graficos balance/equity: embebidos en HTML FULL (y PNG del informe si exportados junto al HTML).

Nota Diario regime: el informe HTML NO exporta la pestana Diario de MT5. Evidencia: `Capturas_E2/Diario-E2-B.png` (`E2 v1.14 regime | BULL | Gate-OFF`; corrida Preset B).

---

## 2. Capturas (`Capturas_E2/` — 6 PNG)

| Archivo | Uso |
|---------|-----|
| Configuración_E2-2016-2023.png | Probador IS (fechas, simbolo, modelado, deposito) |
| Configuración_E2-2023-2026.png | Probador OOS |
| Configuración_E2-2016-2026.png | Probador FULL |
| Inputs-E2-A.png | Preset A: regimen [1][2][3]=true |
| Inputs-E2-B.png | Preset B: ablacion, tres flags=false |
| Diario-E2-B.png | Log regimen v1.14 en tester (Preset B) |

Las tres configuraciones documentan ventanas; en cada backtest se cambiaron inputs A o B segun preset.

Copia de este documento: `Cosas Cursor/Resultados/cierre_practico_E2.md`

---

## 3. Presets

- A (oficial TFG): RequireBullRegime, LongOnlyInBullRegime, CloseOnBearRegime = true
- B (ablacion): los tres = false
- Motor comun: Z=1.8 Mom=1.2 MA20 Mom14 RegimeMA50 slope10 MaxSpread80 tiers 1.5/1.0/0.5

---

## 4. Metricas Preset A

| Ventana | Trades | Net EUR | PF | WR % | Cortos | DD bal rel |
| IS | 63 | +35 526,80 | 1,79 | 57,14 | 0 | 25,00% |
| OOS | 18 | +5 742,74 | 1,85 | 55,56 | 0 | 20,21% |
| FULL | 81 | +61 305,37 | 1,81 | 56,79 | 0 | max 20,18% |

Net(IS)+Net(OOS) != Net(FULL): trades que cruzan corte 10-11/05/2023; FULL es referencia PnL.
XAU buy-hold (CSV): IS +59,0% | OOS +134,8% | FULL +270,5%

---

## 5. Ablacion A vs B (FULL)

| | A | B |
|--|--:|--:|
| Trades | 81 | 193 |
| Net EUR | +61 305 | +48 313 |
| PF | 1,81 | 1,27 |
| Cortos | 0 | 88 |
| DD bal max | 20,18% | 34,46% |

Sin regimen: mas trades, cortos deficitarios, peor PF/DD. Con regimen: interruptor alcista, solo largos.

---

## 6. PnL anual Preset A (FULL, transacciones HTML)

| Ano | Trades | Bot EUR | XAU % | Alineado |
| 2016 | 0 | 0 | +7,2 | - |
| 2017 | 9 | +2 738 | +12,4 | Si |
| 2018 | 11 | +1 789 | -2,9 | No |
| 2019 | 17 | +8 123 | +18,3 | Si |
| 2020 | 10 | +8 243 | +23,9 | Si |
| 2021 | 6 | -1 116 | -5,9 | Si |
| 2022 | 6 | +1 908 | +1,2 | Si |
| 2023 | 8 | +8 383 | +12,2 | Si |
| 2024 | 11 | +22 421 | +27,5 | Si |
| 2025 | 3 | +8 816 | +62,5 | Si |

Alineacion signo: 8/9

---

## 7. Sanidad vs v1.13 FULL

Identico: 81 trades, 0 cortos, +61 305 EUR, PF 1,81, WR 56,79%, DD 20,18%

---

## 8. Protocolo Ficha 2 (Preset A)

| Criterio | Estado |
| Trades IS >= 30 | PASS |
| OOS documentado | PASS |
| Sin re-opt OOS | PASS |
| Calidad ticks | PASS |
| PF OOS vs IS | PASS (+3,4%) |
| 0 cortos (A) | PASS |
| HTML IS+OOS | PASS |
| Capturas config+inputs+Diario | PASS (6 PNG) |
| Resumen metricas | PASS (HTML) |

Veredicto global: PASS — practica E2 cerrada.

---

## 9. Veredicto E2

Practica cerrada: Preset A evidencia oficial, Preset B ablacion, 6 HTML + 6 capturas `Capturas_E2/`.
Rol TFG: viabilidad condicional al regimen (no ganadora global).

Generado 2026-06-04. Actualizado: tancament definitiu (Diario-E2-B.png incluido).