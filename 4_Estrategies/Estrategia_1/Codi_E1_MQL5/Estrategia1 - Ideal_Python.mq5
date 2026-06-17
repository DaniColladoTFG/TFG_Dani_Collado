//+------------------------------------------------------------------+
//|                                                  ABIR_Fase11.mq5 |
//|          Coarse Data Bias validation - Event-driven MT5 EA       |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "ABIR Fase 1.1 - EA para validacion event-driven en MT5"

#include <Trade/Trade.mqh>

CTrade trade;

input double InpLots = 0.10;                      // Tamaño de lote fijo
input int    InpSlippagePoints = 30;              // Desviacion maxima en puntos
input ulong  InpMagicNumber = 20260519;           // Magic number
input string InpOrderComment = "ABIR_Fase11";     // Comentario orden

input int    InpADRPeriod = 14;                   // Periodo ADR
input int    InpBBPeriod = 20;                    // Periodo Bollinger
input double InpBBDeviation = 1.5;                // Desviacion Bollinger
input int    InpVolWindow = 20;                   // Ventana MA(ADR)
input double InpVolMultiplier = 1.05;             // ADR > k * MA(ADR)

input double InpTPMultADR = 0.20;                 // TP = Open + x * ADR
input double InpSLMultADR = 0.20;                 // SL = Open - x * ADR

input int    InpForceExitHour = 23;               // Hora cierre temporal
input int    InpForceExitMinute = 59;             // Minuto cierre temporal

int g_bandsHandle = INVALID_HANDLE;
datetime g_lastD1BarTime = 0;
datetime g_lastForcedCloseDay = 0;

//+------------------------------------------------------------------+
//| Utilidades                                                       |
//+------------------------------------------------------------------+
datetime DayStart(datetime t)
{
   string ds = TimeToString(t, TIME_DATE);
   return StringToTime(ds);
}

bool IsOurPosition(const int idx)
{
   if(!PositionSelectByTicket(PositionGetTicket(idx)))
      return false;

   string symbol = PositionGetString(POSITION_SYMBOL);
   long magic = PositionGetInteger(POSITION_MAGIC);
   return (symbol == _Symbol && (ulong)magic == InpMagicNumber);
}

bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      string symbol = PositionGetString(POSITION_SYMBOL);
      long magic = PositionGetInteger(POSITION_MAGIC);
      if(symbol == _Symbol && (ulong)magic == InpMagicNumber)
         return true;
   }
   return false;
}

void CloseAllOurPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;

      string symbol = PositionGetString(POSITION_SYMBOL);
      long magic = PositionGetInteger(POSITION_MAGIC);
      if(symbol != _Symbol || (ulong)magic != InpMagicNumber)
         continue;

      if(!trade.PositionClose(ticket))
      {
         PrintFormat("Error cerrando posicion ticket=%I64u, retcode=%d",
                     ticket, trade.ResultRetcode());
      }
   }
}

bool IsNewDailyBar()
{
   datetime currentBar = iTime(_Symbol, PERIOD_D1, 0);
   if(currentBar == 0)
      return false;

   if(g_lastD1BarTime == 0)
   {
      g_lastD1BarTime = currentBar;
      return false;
   }

   if(currentBar != g_lastD1BarTime)
   {
      g_lastD1BarTime = currentBar;
      return true;
   }
   return false;
}

double ComputeADR(const MqlRates &rates[], const int shift, const int period)
{
   if(period <= 0)
      return 0.0;

   int bars = ArraySize(rates);
   if(shift + period - 1 >= bars)
      return 0.0;

   double sum = 0.0;
   for(int i = shift; i < shift + period; ++i)
      sum += (rates[i].high - rates[i].low);

   return sum / period;
}

double ComputeADRMA(const MqlRates &rates[], const int shift, const int adrPeriod, const int maWindow)
{
   if(maWindow <= 0)
      return 0.0;

   double sum = 0.0;
   for(int i = 0; i < maWindow; ++i)
   {
      double adr = ComputeADR(rates, shift + i, adrPeriod);
      if(adr <= 0.0)
         return 0.0;
      sum += adr;
   }
   return sum / maWindow;
}

void ManageForceExit()
{
   if(!HasOpenPosition())
      return;

   datetime now = TimeCurrent();
   MqlDateTime dt;
   if(!TimeToStruct(now, dt))
      return;
   int h = dt.hour;
   int m = dt.min;
   if(h < InpForceExitHour || (h == InpForceExitHour && m < InpForceExitMinute))
      return;

   datetime today = DayStart(now);
   if(g_lastForcedCloseDay == today)
      return;

   CloseAllOurPositions();
   g_lastForcedCloseDay = today;
   Print("Cierre temporal ejecutado (>= 23:59 servidor).");
}

bool BuildSignal(bool &signalBuy, double &entryOpen, double &tpPrice, double &slPrice, double &adrPrevOut)
{
   signalBuy = false;
   entryOpen = 0.0;
   tpPrice = 0.0;
   slPrice = 0.0;
   adrPrevOut = 0.0;

   int minBars = InpADRPeriod + InpVolWindow + 10;
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(_Symbol, PERIOD_D1, 0, minBars, rates);
   if(copied < minBars)
   {
      PrintFormat("CopyRates insuficiente. copied=%d minBars=%d", copied, minBars);
      return false;
   }

   double bbLower[];
   ArraySetAsSeries(bbLower, true);
   if(CopyBuffer(g_bandsHandle, 2, 1, 1, bbLower) != 1)
   {
      Print("No se pudo leer banda inferior de Bollinger.");
      return false;
   }

   double closePrev = rates[1].close;
   double openToday = rates[0].open;
   double adrPrev = ComputeADR(rates, 1, InpADRPeriod);
   double adrMaPrev = ComputeADRMA(rates, 1, InpADRPeriod, InpVolWindow);

   if(adrPrev <= 0.0 || adrMaPrev <= 0.0)
      return false;

   bool condCloseBelowBB = (closePrev < bbLower[0]);
   bool condVolExpansion = (adrPrev > InpVolMultiplier * adrMaPrev);
   signalBuy = (condCloseBelowBB && condVolExpansion);

   if(!signalBuy)
      return true;

   entryOpen = openToday;
   adrPrevOut = adrPrev;
   tpPrice = entryOpen + InpTPMultADR * adrPrev;
   slPrice = entryOpen - InpSLMultADR * adrPrev;
   return true;
}

bool PlaceBuyOrder(const double tpPriceRaw, const double slPriceRaw)
{
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int stopLevelPoints = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDistance = stopLevelPoints * point;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(ask <= 0.0)
      return false;

   double tp = tpPriceRaw;
   double sl = slPriceRaw;

   if(minDistance > 0.0)
   {
      if((tp - ask) < minDistance)
         tp = ask + minDistance;
      if((ask - sl) < minDistance)
         sl = ask - minDistance;
   }

   tp = NormalizeDouble(tp, digits);
   sl = NormalizeDouble(sl, digits);

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);

   bool ok = trade.Buy(InpLots, _Symbol, 0.0, sl, tp, InpOrderComment);
   if(!ok)
   {
      PrintFormat("Fallo Buy. retcode=%d, comment=%s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
      return false;
   }

   PrintFormat("BUY enviada. price=%.5f sl=%.5f tp=%.5f", trade.ResultPrice(), sl, tp);
   return true;
}

void ProcessNewD1Bar()
{
   if(HasOpenPosition())
   {
      // Evita reentrada mientras exista una posicion de la estrategia.
      return;
   }

   bool buySignal = false;
   double entry = 0.0, tp = 0.0, sl = 0.0, adrPrev = 0.0;
   if(!BuildSignal(buySignal, entry, tp, sl, adrPrev))
      return;

   if(!buySignal)
      return;

   PrintFormat("Signal BUY detectada: open=%.5f adrPrev=%.5f tp=%.5f sl=%.5f",
               entry, adrPrev, tp, sl);

   PlaceBuyOrder(tp, sl);
}

//+------------------------------------------------------------------+
//| Ciclo de vida EA                                                 |
//+------------------------------------------------------------------+
int OnInit()
{
   g_bandsHandle = iBands(_Symbol, PERIOD_D1, InpBBPeriod, 0, InpBBDeviation, PRICE_CLOSE);
   if(g_bandsHandle == INVALID_HANDLE)
   {
      Print("Error creando handle de Bollinger Bands.");
      return INIT_FAILED;
   }

   g_lastD1BarTime = iTime(_Symbol, PERIOD_D1, 0);
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);

   Print("EA ABIR_Fase11 inicializado.");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_bandsHandle != INVALID_HANDLE)
      IndicatorRelease(g_bandsHandle);
}

void OnTick()
{
   ManageForceExit();

   if(IsNewDailyBar())
      ProcessNewD1Bar();
}
