# TFG_Dani_Collado

# Estudi de la viabilitat d'un model de decisió automatitzat per a mercats financers

**Treball Final de Grau** — Grau en Enginyeria en Tecnologies Industrials  
**Universitat Politècnica de Catalunya (ESEIAAT)** · Curs 2025–2026  

**Autor:** Daniel Collado Bescos  
**Tutor:** Pedro Monagas Asensio  

---

## Resum

Aquest treball analitza la viabilitat tècnica i econòmica d'un sistema de decisió automatitzat aplicat a l'or al comptat (XAU/USD). S'han dissenyat, implementat i validat quatre estratègies algorítmiques complementàries sobre dades de ticks reals, amb separació estricta In-Sample (2016–2023) i Out-of-Sample (2023–2026). La infraestructura integra un doble pipeline en Python i MQL5 (MetaTrader 5). Els resultats determinen que cap estratègia avaluada és viable per al desplegament en compte real; com a contribucions verificables, el treball quantifica el *Coarse Data Bias*, formalitza un protocol IS/OOS per a sistemes rule-based i documenta una arquitectura de backtesting reproducible.

---

## Documentació acadèmica

| Document | Fitxer |
|---|---|
| Memòria | [`Memoria_TFE_Daniel_Collado.pdf`](Memoria_TFE_Daniel_Collado.pdf) |
| Annex | [`Annex_TFE_Daniel_Collado.pdf`](Annex_TFE_Daniel_Collado.pdf) |
| Pressupost | [`Pressupost_TFE_Daniel_Collado.pdf`](Pressupost_TFE_Daniel_Collado.pdf) |

> Els PDF s'afegeixen a l'arrel del repositori en el moment del lliurament.

---

## Estructura del repositori

```
4_Estrategies/
├── Estrategia_1/          # ABIR — quantificació del Coarse Data Bias
│   ├── Capturas_E1/
│   ├── Codi_E1_MQL5/
│   ├── Python/
│   └── Reports_E1/
├── Estrategia_2/          # ZScore Momentum Dynamic — règim de mercat
│   ├── Capturas_E2/
│   ├── Codi_E2_MQL5/
│   └── Reports_E2/
├── Estrategia_3/          # Grid-Martingale — anti-model de risc exponencial
│   ├── Capturas_E3/
│   ├── Codi_E3_MQL5/
│   └── Reports_E3/
└── Estrategia_4/          # Família Donchian D1 — referència de viabilitat
    ├── Baseline (No def)/
    ├── Capturas_E4/
    ├── E4_a - Donchain Definitiva/
    │   ├── Capturas_E4_a/
    │   ├── Codi_E4_a_MQL5/
    │   └── Reports_E4_a/
    ├── E4_b - Donchain_Breakout/
    │   ├── Capturas_E4_b/
    │   ├── Codi_E4_b_MQL5/
    │   └── Reports_E4_b/
    ├── E4_c - Adaptative_Regime/
    │   ├── Capturas_E4_c/
    │   ├── Codi_E4_c_MQL5/
    │   └── Reports_E4_c/
    └── E4_d - Donchian_Fusion/
        ├── Capturas_E4_d/
        ├── Codi_E4_d_MQL5/
        └── Reports_E4_d/
```

| Carpeta | Contingut |
|---|---|
| `Capturas_*` | Captures de pantalla del probador de estratègies MT5 |
| `Codi_*_MQL5` | Codi font dels Expert Advisors (`.mq5`) |
| `Python` | Motor de referència ABIR (només Estratègia 1) |
| `Reports_*` | Informes HTML/CSV de backtesting |

---

## Stack tecnològic

- **Python 3** — motor de referència ABIR (Estratègia 1) i anàlisi auxiliar
- **MQL5 / MetaTrader 5** — implementació i execució dels backtests
- **Dades:** ticks reals XAUUSD (~99–100 %), exportades via Quant Data Manager

### Paràmetres globals de simulació

| Paràmetre | Valor |
|---|---|
| Actiu | XAUUSD |
| Timeframe | D1 |
| Capital inicial | 10.000 EUR |
| Apalancament | 1:20 |
| In-Sample | 11/05/2016 – 10/05/2023 |
| Out-of-Sample | 11/05/2023 – 11/05/2026 |

---

## Reproducció

1. Clonar el repositori.
2. Obrir els fitxers `.mq5` de cada estratègia a MetaTrader 5 i compilar-los com a Expert Advisors.
3. Importar l'historial de ticks XAUUSD al terminal (dades no incloses al repo per limitació de mida; font: Quant Data Manager).
4. Executar el probador de estratègies amb el model **«Cada tick basat en ticks reals»** i els paràmetres indicats a la memòria.
5. Comparar els resultats amb els informes de les carpetes `Reports_*` i les captures de `Capturas_*`.

> Projecte acadèmic amb finalitat d'investigació i validació metodològica. No constitueix assessorament financer ni recomanació d'inversió.

---

## Enllaços

- **Repositori:** [github.com/DaniColladoTFG/TFG_Dani_Collado](https://github.com/DaniColladoTFG/TFG_Dani_Collado)
- **Autor:** [github.com/DaniColladoTFG](https://github.com/DaniColladoTFG)
