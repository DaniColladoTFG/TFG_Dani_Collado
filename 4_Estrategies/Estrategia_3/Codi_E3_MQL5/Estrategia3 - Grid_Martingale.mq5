#property strict
#property version   "1.0"
#property description "TFG E3 Grid-Martingale D1 — modos V1 Ruina | V2 Parada total | V3 Fusible+resume."
#property description "V3_1 = V3 + InpMaxBasketLossUSD>0. Const agresivas fijas. Exporta cycles_*.csv."

#include <Trade/Trade.mqh>

// Parametros fijos e innegociables (no optimizar en probador)
const double BASE_LOT              = 0.05;
const double GRID_STEP_USD         = 3.0;
const double MARTINGALE_MULT       = 2.0;
const double BASKET_TP_USD         = 50.0;
const double MARGIN_CALL_LEVEL_PCT = 100.0;
const double STOP_OUT_LEVEL_PCT    = 50.0;
const long   MAGIC_NUMBER          = 20260519;

// Modo de experimento (un solo .mq5; cambiar input entre backtests)
enum E3RunMode
{
   E3_V1_RUINA = 0,          // Sin fusible EA; sin parada global; busca ruina de cuenta
   E3_V2_PARADA_TOTAL = 1,   // Colapso -> apaga EA (protocolo original)
   E3_V3_FUSIBLE_RESUME = 2   // Fusible margen (+ tope USD opcional); sigue operando
};

input E3RunMode InpMode = E3_V2_PARADA_TOTAL;
input datetime InpStartDate = D'2016.05.11 00:00';
input datetime InpEndDate   = D'2026.05.11 00:00';
// Solo V3: 0 = solo fusible por margen; >0 activa corrida V3_1 (tope perdida flotante cesta, USD)
input double InpMaxBasketLossUSD = 0.0;

CTrade trade;

enum CycleCloseReason
{
   CLOSE_UNKNOWN = 0,
   CLOSE_BASKET_TP,
   CLOSE_STOP_OUT_BROKER,
   CLOSE_MARGIN_COLLAPSE_EA,
   CLOSE_BASKET_LOSS_CAP,
   CLOSE_MANUAL_FAILSAFE
};

struct CycleSummary
{
   int      cycle_id;
   datetime start_time;
   datetime end_time;
   string   close_reason;
   double   realized_pnl;
   double   commission;
   double   swap;
   double   gross_profit;
   double   gross_loss;
   int      entry_count;
   int      max_level_reached;
   double   peak_total_lots;
   double   min_margin_level_pct;
   double   max_floating_dd_abs;
   int      win_flag;
};

struct CycleEvent
{
   datetime t;
   int      cycle_id;
   string   event_type;
   double   price;
   double   volume;
   int      positions_open;
   double   margin_level_pct;
   double   free_margin;
   string   note;
};

CycleSummary g_cycles[];
CycleEvent   g_events[];

// Estado operativo
int    g_current_cycle_id = 0;
bool   g_cycle_active = false;
bool   g_cycle_had_positions = false;
bool   g_hard_stopped = false;
datetime g_last_bar_time = 0;

double g_next_lot = BASE_LOT;
double g_next_grid_price = 0.0;
bool   g_has_next_grid = false;
bool   g_grid_halted_by_limits = false;
datetime g_last_flat_entry_bar = 0;

// Cierre asincrono: solo se finaliza ciclo tras procesar deals de salida
bool             g_close_requested = false;
CycleCloseReason g_close_reason_pending = CLOSE_UNKNOWN;
datetime         g_close_request_time = 0;
bool             g_cycle_seen_exit_deal = false;

// Acumuladores ciclo activo
datetime g_cycle_start = 0;
double   g_cycle_realized = 0.0;
double   g_cycle_commission = 0.0;
double   g_cycle_swap = 0.0;
double   g_cycle_gross_profit = 0.0;
double   g_cycle_gross_loss = 0.0;
int      g_cycle_entry_count = 0;
double   g_cycle_peak_lots = 0.0;
double   g_cycle_min_margin_level = DBL_MAX;
double   g_cycle_max_floating_dd_abs = 0.0;

// Datos de volumen del simbolo para cortafuegos de lote
double g_symbol_vol_min = 0.0;
double g_symbol_vol_max = 0.0;
double g_symbol_vol_step = 0.0;

string ReasonToString(CycleCloseReason r)
{
   switch(r)
   {
      case CLOSE_BASKET_TP:          return "BASKET_TP";
      case CLOSE_STOP_OUT_BROKER:    return "STOP_OUT_BROKER";
      case CLOSE_MARGIN_COLLAPSE_EA: return "MARGIN_COLLAPSE_EA";
      case CLOSE_BASKET_LOSS_CAP:    return "BASKET_LOSS_CAP";
      case CLOSE_MANUAL_FAILSAFE:    return "MANUAL_FAILSAFE";
      default:                       return "UNKNOWN";
   }
}

bool ModeUsesHardStopAfterCollapse()
{
   return (InpMode == E3_V2_PARADA_TOTAL);
}

bool ModeUsesEAMarginGuard()
{
   return (InpMode == E3_V2_PARADA_TOTAL || InpMode == E3_V3_FUSIBLE_RESUME);
}

bool ModeUsesBasketLossCap()
{
   return (InpMode == E3_V3_FUSIBLE_RESUME && InpMaxBasketLossUSD > 0.0);
}

string ModeLabel()
{
   if(InpMode == E3_V1_RUINA)
      return "V1_RUINA";
   if(InpMode == E3_V2_PARADA_TOTAL)
      return "V2_PARADA_TOTAL";
   if(ModeUsesBasketLossCap())
      return "V3_1_FUSIBLE_TOPE";
   return "V3_FUSIBLE_RESUME";
}

bool InDateRange(datetime t)
{
   return (t >= InpStartDate && t <= InpEndDate);
}

bool IsSymbolTradingEnabled()
{
   long mode = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   return (mode == SYMBOL_TRADE_MODE_FULL || mode == SYMBOL_TRADE_MODE_LONGONLY);
}

bool IsNewD1Bar(datetime bar_t)
{
   if(bar_t == 0) return false;
   if(bar_t != g_last_bar_time)
   {
      g_last_bar_time = bar_t;
      return true;
   }
   return false;
}

void PushEvent(datetime t,
               int cycle_id,
               string event_type,
               double price,
               double volume,
               int positions_open,
               double margin_level_pct,
               double free_margin,
               string note)
{
   int n = ArraySize(g_events);
   ArrayResize(g_events, n + 1);
   g_events[n].t = t;
   g_events[n].cycle_id = cycle_id;
   g_events[n].event_type = event_type;
   g_events[n].price = price;
   g_events[n].volume = volume;
   g_events[n].positions_open = positions_open;
   g_events[n].margin_level_pct = margin_level_pct;
   g_events[n].free_margin = free_margin;
   g_events[n].note = note;
}

bool IsOurPositionByTicket(ulong ticket)
{
   if(ticket == 0) return false;
   if(!PositionSelectByTicket(ticket)) return false;
   if(PositionGetString(POSITION_SYMBOL) != _Symbol) return false;
   if((long)PositionGetInteger(POSITION_MAGIC) != MAGIC_NUMBER) return false;
   return true;
}

bool IsOurOrderByTicket(ulong ticket)
{
   if(ticket == 0) return false;
   if(!OrderSelect(ticket)) return false;
   if(OrderGetString(ORDER_SYMBOL) != _Symbol) return false;
   if((long)OrderGetInteger(ORDER_MAGIC) != MAGIC_NUMBER) return false;
   return true;
}

int CountOurOpenPositions()
{
   int total = 0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong tk = PositionGetTicket(i);
      if(IsOurPositionByTicket(tk))
         total++;
   }
   return total;
}

int CountOurPendingSellLimits()
{
   int total = 0;
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      ulong tk = OrderGetTicket(i);
      if(!IsOurOrderByTicket(tk)) continue;
      ENUM_ORDER_TYPE tp = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(tp == ORDER_TYPE_SELL_LIMIT)
         total++;
   }
   return total;
}

double TotalLotsOpen()
{
   double lots = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong tk = PositionGetTicket(i);
      if(!IsOurPositionByTicket(tk)) continue;
      lots += PositionGetDouble(POSITION_VOLUME);
   }
   return lots;
}

double HighestEntryOpen()
{
   double mx = -DBL_MAX;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong tk = PositionGetTicket(i);
      if(!IsOurPositionByTicket(tk)) continue;
      double ep = PositionGetDouble(POSITION_PRICE_OPEN);
      if(ep > mx) mx = ep;
   }
   if(mx == -DBL_MAX) return 0.0;
   return mx;
}

double HighestOpenVolume()
{
   double mx = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong tk = PositionGetTicket(i);
      if(!IsOurPositionByTicket(tk)) continue;
      double vol = PositionGetDouble(POSITION_VOLUME);
      if(vol > mx) mx = vol;
   }
   return mx;
}

double BasketFloatingProfit()
{
   double p = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong tk = PositionGetTicket(i);
      if(!IsOurPositionByTicket(tk)) continue;
      p += PositionGetDouble(POSITION_PROFIT);
   }
   return p;
}

void ResetCycleAccumulators()
{
   g_cycle_start = 0;
   g_cycle_realized = 0.0;
   g_cycle_commission = 0.0;
   g_cycle_swap = 0.0;
   g_cycle_gross_profit = 0.0;
   g_cycle_gross_loss = 0.0;
   g_cycle_entry_count = 0;
   g_cycle_peak_lots = 0.0;
   g_cycle_min_margin_level = DBL_MAX;
   g_cycle_max_floating_dd_abs = 0.0;
   g_cycle_seen_exit_deal = false;
   g_grid_halted_by_limits = false;
}

double Clamp(double value, double lo, double hi)
{
   if(value < lo) return lo;
   if(value > hi) return hi;
   return value;
}

double FloorToStep(double value, double step)
{
   if(step <= 0.0) return value;
   return MathFloor(value / step + 1e-12) * step;
}

int VolumeDigitsFromStep(double step)
{
   if(step <= 0.0 || !MathIsValidNumber(step)) return 2;
   string s = DoubleToString(step, 8);
   int len = StringLen(s);
   int dot = StringFind(s, ".");
   if(dot < 0) return 0;

   int last_non_zero = -1;
   for(int i = len - 1; i > dot; --i)
   {
      if(StringGetCharacter(s, i) != '0')
      {
         last_non_zero = i;
         break;
      }
   }

   if(last_non_zero < 0) return 0;
   return last_non_zero - dot;
}

bool GetSanitizedLot(double desired_lot, double &safe_lot, string &note)
{
   note = "";
   safe_lot = 0.0;

   if(!MathIsValidNumber(desired_lot) || desired_lot <= 0.0)
   {
      note = "invalid desired lot";
      return false;
   }

   if(g_symbol_vol_max <= 0.0 || g_symbol_vol_min <= 0.0 || g_symbol_vol_step <= 0.0)
   {
      note = "symbol volume constraints invalid";
      return false;
   }

   double lot = desired_lot;
   if(lot > g_symbol_vol_max)
   {
      note = "exceeds_symbol_max";
      return false;
   }

   lot = Clamp(lot, g_symbol_vol_min, g_symbol_vol_max);
   lot = FloorToStep(lot, g_symbol_vol_step);
   lot = Clamp(lot, g_symbol_vol_min, g_symbol_vol_max);

   if(!MathIsValidNumber(lot) || lot < g_symbol_vol_min || lot > g_symbol_vol_max)
   {
      note = "sanitized lot out of bounds";
      return false;
   }

   int vol_digits = VolumeDigitsFromStep(g_symbol_vol_step);
   safe_lot = NormalizeDouble(lot, vol_digits);
   return true;
}

bool HasMarginForVolume(double volume, double ref_price, double &required_margin)
{
   required_margin = 0.0;
   if(!MathIsValidNumber(volume) || volume <= 0.0) return false;

   double px = ref_price;
   if(!MathIsValidNumber(px) || px <= 0.0)
      px = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(!MathIsValidNumber(px) || px <= 0.0)
      return false;

   if(!OrderCalcMargin(ORDER_TYPE_SELL, _Symbol, volume, px, required_margin))
      return false;

   double free_margin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   return (required_margin > 0.0 && free_margin >= required_margin);
}

bool SafeMartingaleNext(double current_lot, double mult, double &next_lot)
{
   if(!MathIsValidNumber(current_lot) || !MathIsValidNumber(mult) || current_lot <= 0.0 || mult <= 0.0)
      return false;
   if(current_lot > DBL_MAX / mult)
      next_lot = DBL_MAX;
   else
      next_lot = current_lot * mult;
   return MathIsValidNumber(next_lot) && next_lot > 0.0;
}

void BeginNewCycle(datetime t)
{
   g_current_cycle_id++;
   g_cycle_active = true;
   g_cycle_had_positions = true;
   ResetCycleAccumulators();
   g_cycle_start = t;

   g_next_lot = BASE_LOT;
   g_has_next_grid = false;
   g_next_grid_price = 0.0;
   g_grid_halted_by_limits = false;
   g_close_requested = false;
   g_close_reason_pending = CLOSE_UNKNOWN;
   g_close_request_time = 0;

   PushEvent(t, g_current_cycle_id, "CYCLE_START", 0.0, 0.0, CountOurOpenPositions(),
             AccountInfoDouble(ACCOUNT_MARGIN_LEVEL), AccountInfoDouble(ACCOUNT_MARGIN_FREE), "");
}

void FinalizeCycle(datetime t)
{
   if(!g_cycle_active) return;

   int n = ArraySize(g_cycles);
   ArrayResize(g_cycles, n + 1);
   g_cycles[n].cycle_id = g_current_cycle_id;
   g_cycles[n].start_time = g_cycle_start;
   g_cycles[n].end_time = t;
   g_cycles[n].close_reason = ReasonToString(g_close_reason_pending);
   g_cycles[n].realized_pnl = g_cycle_realized;
   g_cycles[n].commission = g_cycle_commission;
   g_cycles[n].swap = g_cycle_swap;
   g_cycles[n].gross_profit = g_cycle_gross_profit;
   g_cycles[n].gross_loss = g_cycle_gross_loss;
   g_cycles[n].entry_count = g_cycle_entry_count;
   g_cycles[n].max_level_reached = (g_cycle_entry_count > 0 ? g_cycle_entry_count - 1 : 0);
   g_cycles[n].peak_total_lots = g_cycle_peak_lots;
   g_cycles[n].min_margin_level_pct = (g_cycle_min_margin_level >= DBL_MAX / 10.0 ? 0.0 : g_cycle_min_margin_level);
   g_cycles[n].max_floating_dd_abs = g_cycle_max_floating_dd_abs;
   g_cycles[n].win_flag = (g_cycle_realized > 0.0 ? 1 : 0);

   PushEvent(t, g_current_cycle_id, "CYCLE_END", 0.0, 0.0, 0,
             AccountInfoDouble(ACCOUNT_MARGIN_LEVEL), AccountInfoDouble(ACCOUNT_MARGIN_FREE),
             g_cycles[n].close_reason);

   if(ModeUsesHardStopAfterCollapse() &&
      (g_close_reason_pending == CLOSE_MARGIN_COLLAPSE_EA || g_close_reason_pending == CLOSE_STOP_OUT_BROKER))
      g_hard_stopped = true;

   g_cycle_active = false;
   g_cycle_had_positions = false;
   g_close_requested = false;
   g_close_reason_pending = CLOSE_UNKNOWN;
   g_close_request_time = 0;
   ResetCycleAccumulators();
   g_next_lot = BASE_LOT;
   g_has_next_grid = false;
   g_next_grid_price = 0.0;
   g_grid_halted_by_limits = false;
}

void TryFinalizeCycleFromTransactions(datetime now_t)
{
   if(!g_cycle_active || !g_cycle_had_positions) return;

   int open_pos = CountOurOpenPositions();
   int open_pending = CountOurPendingSellLimits();
   if(open_pos != 0 || open_pending != 0) return;

   // Cierre robusto: solo cuando ya se vieron deals de salida de ese ciclo.
   if(!g_cycle_seen_exit_deal) return;

   if(g_close_reason_pending == CLOSE_UNKNOWN)
      g_close_reason_pending = CLOSE_MANUAL_FAILSAFE;

   FinalizeCycle(now_t);
}

void UpdateLiveRiskMetrics()
{
   if(!g_cycle_active) return;
   int open_pos = CountOurOpenPositions();
   if(open_pos <= 0) return;

   double lots = TotalLotsOpen();
   if(lots > g_cycle_peak_lots) g_cycle_peak_lots = lots;

   double ml = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   if(ml > 0.0 && ml < g_cycle_min_margin_level) g_cycle_min_margin_level = ml;

   double fp = BasketFloatingProfit();
   if(fp < 0.0)
   {
      double dd = -fp;
      if(dd > g_cycle_max_floating_dd_abs) g_cycle_max_floating_dd_abs = dd;
   }
}

void RequestCloseAll(CycleCloseReason reason, string note)
{
   if(g_close_requested) return;
   g_close_requested = true;
   g_close_reason_pending = reason;
   g_close_request_time = TimeCurrent();
   PushEvent(g_close_request_time, g_current_cycle_id, "CLOSE_REQUEST", 0.0, 0.0,
             CountOurOpenPositions(), AccountInfoDouble(ACCOUNT_MARGIN_LEVEL), AccountInfoDouble(ACCOUNT_MARGIN_FREE), note);
}

void DeleteOurPendingSellLimits()
{
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      ulong tk = OrderGetTicket(i);
      if(!IsOurOrderByTicket(tk)) continue;
      ENUM_ORDER_TYPE tp = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(tp == ORDER_TYPE_SELL_LIMIT)
         trade.OrderDelete(tk);
   }
}

void CloseOurOpenPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong tk = PositionGetTicket(i);
      if(!IsOurPositionByTicket(tk)) continue;
      trade.PositionClose(tk);
   }
}

bool PlaceNextSellLimit(datetime t)
{
   if(!g_has_next_grid) return false;
   if(g_grid_halted_by_limits) return false;

   double safe_lot = 0.0;
   string lot_note = "";
   if(!GetSanitizedLot(g_next_lot, safe_lot, lot_note))
   {
      PushEvent(t, g_current_cycle_id, "BLOCK_SELL_LIMIT", g_next_grid_price, g_next_lot,
                CountOurOpenPositions(), AccountInfoDouble(ACCOUNT_MARGIN_LEVEL), AccountInfoDouble(ACCOUNT_MARGIN_FREE),
                "lot_sanitize_fail:" + lot_note);
      g_grid_halted_by_limits = true;
      g_has_next_grid = false;
      PushEvent(t, g_current_cycle_id, "GRID_HALTED", g_next_grid_price, g_next_lot,
                CountOurOpenPositions(), AccountInfoDouble(ACCOUNT_MARGIN_LEVEL), AccountInfoDouble(ACCOUNT_MARGIN_FREE),
                "halted_by_symbol_limits");
      return false;
   }

   double required_margin = 0.0;
   if(!HasMarginForVolume(safe_lot, g_next_grid_price, required_margin))
   {
      PushEvent(t, g_current_cycle_id, "BLOCK_SELL_LIMIT", g_next_grid_price, safe_lot,
                CountOurOpenPositions(), AccountInfoDouble(ACCOUNT_MARGIN_LEVEL), AccountInfoDouble(ACCOUNT_MARGIN_FREE),
                "insufficient_margin_for_next_level;required=" + DoubleToString(required_margin, 2));
      g_grid_halted_by_limits = true;
      g_has_next_grid = false;
      PushEvent(t, g_current_cycle_id, "GRID_HALTED", g_next_grid_price, safe_lot,
                CountOurOpenPositions(), AccountInfoDouble(ACCOUNT_MARGIN_LEVEL), AccountInfoDouble(ACCOUNT_MARGIN_FREE),
                "halted_by_margin");
      return false;
   }

   bool ok = trade.SellLimit(safe_lot, g_next_grid_price, _Symbol, 0.0, 0.0, ORDER_TIME_GTC, 0, "GRID_SELL_LIMIT");
   PushEvent(t, g_current_cycle_id, "PLACE_SELL_LIMIT", g_next_grid_price, safe_lot,
             CountOurOpenPositions(), AccountInfoDouble(ACCOUNT_MARGIN_LEVEL), AccountInfoDouble(ACCOUNT_MARGIN_FREE),
             (ok ? (lot_note == "" ? "ok" : lot_note) : trade.ResultRetcodeDescription()));
   return ok;
}

bool OpenBaseSell(datetime t)
{
   double base_lot_safe = 0.0;
   string lot_note = "";
   if(!GetSanitizedLot(BASE_LOT, base_lot_safe, lot_note))
   {
      PushEvent(t, g_current_cycle_id, "BLOCK_BASE_SELL", 0.0, BASE_LOT, CountOurOpenPositions(),
                AccountInfoDouble(ACCOUNT_MARGIN_LEVEL), AccountInfoDouble(ACCOUNT_MARGIN_FREE),
                "base lot sanitize fail:" + lot_note);
      return false;
   }

   bool ok = trade.Sell(base_lot_safe, _Symbol, 0.0, 0.0, 0.0, "BASE_SELL");
   PushEvent(t, g_current_cycle_id, "OPEN_BASE_SELL", 0.0, base_lot_safe,
             CountOurOpenPositions(), AccountInfoDouble(ACCOUNT_MARGIN_LEVEL), AccountInfoDouble(ACCOUNT_MARGIN_FREE),
             (ok ? "ok" : trade.ResultRetcodeDescription()));
   if(!ok) return false;

   if(!g_cycle_active && CountOurOpenPositions() > 0)
      BeginNewCycle(t);

   double ref = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double next_raw = 0.0;
   if(!SafeMartingaleNext(base_lot_safe, MARTINGALE_MULT, next_raw))
      next_raw = DBL_MAX;
   g_next_lot = next_raw;
   g_next_grid_price = ref + GRID_STEP_USD;
   g_has_next_grid = true;
   g_grid_halted_by_limits = false;
   return true;
}

void ManageStrategy(datetime t, datetime bar_t, bool new_bar)
{
   if(g_hard_stopped) return;

   int open_pos = CountOurOpenPositions();
   int pending = CountOurPendingSellLimits();

   // Sin posiciones: como maximo un intento de entrada por vela D1 (evita spam market closed en cada tick).
   if(open_pos == 0 && pending == 0 && !g_close_requested)
   {
      if(!new_bar || bar_t == g_last_flat_entry_bar) return;
      if(!IsSymbolTradingEnabled()) return;
      g_last_flat_entry_bar = bar_t;
      if(OpenBaseSell(t))
         PlaceNextSellLimit(t);
      return;
   }

   // Si hay posiciones y no hay pendiente, preparar siguiente nivel.
   if(open_pos > 0 && pending == 0 && !g_close_requested && !g_grid_halted_by_limits)
   {
      double highest = HighestEntryOpen();
      double max_open_vol = HighestOpenVolume();
      if(highest > 0.0 && max_open_vol > 0.0)
      {
         g_next_grid_price = highest + GRID_STEP_USD;
         // Escalado anclado al mayor lote REALMENTE abierto, no al ultimo intento.
         double next_raw = 0.0;
         if(!SafeMartingaleNext(max_open_vol, MARTINGALE_MULT, next_raw))
            next_raw = DBL_MAX;
         g_next_lot = next_raw;
         g_has_next_grid = true;
         PlaceNextSellLimit(t);
      }
   }

   double fp = BasketFloatingProfit();

   // V3_1: tope de perdida flotante de cesta (antes de TP; mismo tick puede aplicar margen despues)
   if(open_pos > 0 && !g_close_requested && ModeUsesBasketLossCap())
   {
      if(fp <= -InpMaxBasketLossUSD)
         RequestCloseAll(CLOSE_BASKET_LOSS_CAP,
                          "basket loss cap " + DoubleToString(InpMaxBasketLossUSD, 0) + " USD");
   }

   // V2/V3: cierre por margen EA. V1: solo stop-out del broker (sin este guardia).
   if(open_pos > 0 && !g_close_requested && ModeUsesEAMarginGuard())
   {
      double ml = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
      double fm = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      if((ml > 0.0 && (ml <= STOP_OUT_LEVEL_PCT || ml <= MARGIN_CALL_LEVEL_PCT)) || fm <= 0.0)
         RequestCloseAll(CLOSE_MARGIN_COLLAPSE_EA, "margin breach");
   }

   if(open_pos > 0 && !g_close_requested)
   {
      if(fp >= BASKET_TP_USD)
         RequestCloseAll(CLOSE_BASKET_TP, "basket tp reached");
   }

   if(g_close_requested)
   {
      DeleteOurPendingSellLimits();
      CloseOurOpenPositions();
   }
}

void FlushCsvOnDeinit()
{
   int fh1 = FileOpen("cycles_summary.csv", FILE_WRITE | FILE_CSV | FILE_ANSI);
   if(fh1 != INVALID_HANDLE)
   {
      FileWrite(fh1,
                "cycle_id","start_time","end_time","close_reason","realized_pnl","commission","swap",
                "gross_profit","gross_loss","entry_count","max_level_reached","peak_total_lots",
                "min_margin_level_pct","max_floating_dd_abs","win_flag");

      for(int i = 0; i < ArraySize(g_cycles); i++)
      {
         FileWrite(fh1,
                   (string)g_cycles[i].cycle_id,
                   TimeToString(g_cycles[i].start_time, TIME_DATE | TIME_SECONDS),
                   TimeToString(g_cycles[i].end_time, TIME_DATE | TIME_SECONDS),
                   g_cycles[i].close_reason,
                   DoubleToString(g_cycles[i].realized_pnl, 2),
                   DoubleToString(g_cycles[i].commission, 2),
                   DoubleToString(g_cycles[i].swap, 2),
                   DoubleToString(g_cycles[i].gross_profit, 2),
                   DoubleToString(g_cycles[i].gross_loss, 2),
                   (string)g_cycles[i].entry_count,
                   (string)g_cycles[i].max_level_reached,
                   DoubleToString(g_cycles[i].peak_total_lots, 2),
                   DoubleToString(g_cycles[i].min_margin_level_pct, 6),
                   DoubleToString(g_cycles[i].max_floating_dd_abs, 2),
                   (string)g_cycles[i].win_flag
                  );
      }
      FileClose(fh1);
   }

   int fh2 = FileOpen("cycles_events.csv", FILE_WRITE | FILE_CSV | FILE_ANSI);
   if(fh2 != INVALID_HANDLE)
   {
      FileWrite(fh2, "timestamp","cycle_id","event_type","price","volume","positions_open","margin_level_pct","free_margin","note");
      for(int j = 0; j < ArraySize(g_events); j++)
      {
         FileWrite(fh2,
                   TimeToString(g_events[j].t, TIME_DATE | TIME_SECONDS),
                   (string)g_events[j].cycle_id,
                   g_events[j].event_type,
                   DoubleToString(g_events[j].price, _Digits),
                   DoubleToString(g_events[j].volume, 4),
                   (string)g_events[j].positions_open,
                   DoubleToString(g_events[j].margin_level_pct, 6),
                   DoubleToString(g_events[j].free_margin, 2),
                   g_events[j].note
                  );
      }
      FileClose(fh2);
   }
}

int OnInit()
{
   trade.SetExpertMagicNumber(MAGIC_NUMBER);
   trade.SetDeviationInPoints(50);

   if(InpMode == E3_V3_FUSIBLE_RESUME && InpMaxBasketLossUSD < 0.0)
   {
      Print("InpMaxBasketLossUSD invalido; use 0 o valor positivo.");
      return INIT_PARAMETERS_INCORRECT;
   }

   Print("E3 Grid-Martingale modo=", ModeLabel(),
         " | margin_guard=", (ModeUsesEAMarginGuard() ? "ON" : "OFF"),
         " | hard_stop=", (ModeUsesHardStopAfterCollapse() ? "ON" : "OFF"),
         (ModeUsesBasketLossCap() ? (" | basket_cap=" + DoubleToString(InpMaxBasketLossUSD, 0) + " USD") : ""));

   g_symbol_vol_min = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   g_symbol_vol_max = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   g_symbol_vol_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(g_symbol_vol_min <= 0.0 || g_symbol_vol_max <= 0.0 || g_symbol_vol_step <= 0.0)
   {
      Print("No se pudieron cargar limites de volumen del simbolo.");
      return INIT_FAILED;
   }

   ResetCycleAccumulators();
   return INIT_SUCCEEDED;
}

void OnTick()
{
   datetime bar_t = iTime(_Symbol, PERIOD_D1, 0);
   if(bar_t == 0) return;
   if(!InDateRange(bar_t)) return;

   bool new_bar = IsNewD1Bar(bar_t);

   if(!g_cycle_active && CountOurOpenPositions() > 0)
      BeginNewCycle(TimeCurrent());

   UpdateLiveRiskMetrics();
   ManageStrategy(TimeCurrent(), bar_t, new_bar);
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   datetime now_t = TimeCurrent();

   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      ulong deal = trans.deal;
      if(deal > 0 && HistoryDealSelect(deal))
      {
         string sym = HistoryDealGetString(deal, DEAL_SYMBOL);
         long mg = (long)HistoryDealGetInteger(deal, DEAL_MAGIC);
         if(sym == _Symbol && mg == MAGIC_NUMBER)
         {
            if(!g_cycle_active)
               BeginNewCycle(now_t);

            ENUM_DEAL_ENTRY de = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY);
            ENUM_DEAL_REASON dr = (ENUM_DEAL_REASON)HistoryDealGetInteger(deal, DEAL_REASON);
            double price = HistoryDealGetDouble(deal, DEAL_PRICE);
            double vol = HistoryDealGetDouble(deal, DEAL_VOLUME);
            double profit = HistoryDealGetDouble(deal, DEAL_PROFIT);
            double comm = HistoryDealGetDouble(deal, DEAL_COMMISSION);
            double swap = HistoryDealGetDouble(deal, DEAL_SWAP);

            if(de == DEAL_ENTRY_IN || de == DEAL_ENTRY_INOUT)
               g_cycle_entry_count++;

            if(de == DEAL_ENTRY_OUT || de == DEAL_ENTRY_OUT_BY || de == DEAL_ENTRY_INOUT)
            {
               g_cycle_seen_exit_deal = true;
               double net = profit + comm + swap;
               g_cycle_realized += net;
               g_cycle_commission += comm;
               g_cycle_swap += swap;
               if(net > 0.0) g_cycle_gross_profit += net;
               else          g_cycle_gross_loss += net;
            }

            if(dr == DEAL_REASON_SO)
            {
               if(g_close_reason_pending == CLOSE_UNKNOWN)
                  g_close_reason_pending = CLOSE_STOP_OUT_BROKER;
               g_close_requested = true;
            }

            PushEvent(now_t, g_current_cycle_id, "DEAL_ADD", price, vol,
                      CountOurOpenPositions(), AccountInfoDouble(ACCOUNT_MARGIN_LEVEL), AccountInfoDouble(ACCOUNT_MARGIN_FREE),
                      "entry=" + IntegerToString((int)de) +
                      ";reason=" + IntegerToString((int)dr) +
                      ";net=" + DoubleToString(profit + comm + swap, 2));
         }
      }
   }
   else if(trans.type == TRADE_TRANSACTION_ORDER_DELETE ||
           trans.type == TRADE_TRANSACTION_ORDER_UPDATE ||
           trans.type == TRADE_TRANSACTION_ORDER_ADD)
   {
      ulong ord = trans.order;
      if(ord > 0 && IsOurOrderByTicket(ord))
      {
         string note = "order_state=" + IntegerToString((int)OrderGetInteger(ORDER_STATE));
         PushEvent(now_t, g_current_cycle_id, "ORDER_EVENT", trans.price, trans.volume,
                   CountOurOpenPositions(), AccountInfoDouble(ACCOUNT_MARGIN_LEVEL), AccountInfoDouble(ACCOUNT_MARGIN_FREE), note);
      }
   }

   UpdateLiveRiskMetrics();
   TryFinalizeCycleFromTransactions(now_t);
}

void OnDeinit(const int reason)
{
   datetime now_t = TimeCurrent();

   // Si el test termina con ciclo activo pero sin posiciones, forzamos cierre de fila (evita perder ciclo final).
   if(g_cycle_active && CountOurOpenPositions() == 0 && CountOurPendingSellLimits() == 0)
   {
      if(g_close_reason_pending == CLOSE_UNKNOWN)
         g_close_reason_pending = CLOSE_MANUAL_FAILSAFE;
      FinalizeCycle(now_t);
   }

   // Si aun hay posiciones abiertas, se intenta cierre defensivo y luego finaliza.
   if(g_cycle_active && CountOurOpenPositions() > 0)
   {
      RequestCloseAll(CLOSE_MANUAL_FAILSAFE, "deinit forced close");
      DeleteOurPendingSellLimits();
      CloseOurOpenPositions();
      if(g_close_reason_pending == CLOSE_UNKNOWN)
         g_close_reason_pending = CLOSE_MANUAL_FAILSAFE;
      // Sin eventos adicionales garantizados en deinit, dejamos constancia y finalizamos.
      g_cycle_seen_exit_deal = true;
      FinalizeCycle(now_t);
   }

   FlushCsvOnDeinit();
}

