#property copyright "TFG Bot Trading"
#property version   "1.01"
#property strict

#include <Trade/Trade.mqh>

CTrade trade_Adaptive_Regime_D1;

input group "Operativa"
input ENUM_TIMEFRAMES InpTimeframe      = PERIOD_D1;

input group "Motor TREND (EMA)"
input int             InpEmaFastPeriod  = 20;
input int             InpEmaSlowPeriod  = 200;

input group "Detector de regimen (ADX + BB)"
input int             InpADXPeriod      = 14;
input double          InpADXTrend       = 20.0;
input double          InpADXRange       = 16.0;
input int             InpBBPeriod       = 30;
input double          InpBBStdDev       = 2.2;
input double          InpRangeBBWMax    = 0.035;

input group "Motor RANGE (RSI + BB)"
input int             InpRSIPeriod      = 7;
input double          InpRSILow         = 25.0;
input double          InpRSIHigh        = 80.0;

input group "Salidas y riesgo"
input int             InpATRPeriod      = 20;
input double          InpSL_ATR         = 2.5;
input double          InpTrailATR       = 2.5;
input int             InpMaxHoldBars    = 15;
input bool            InpAllowShort     = true;

input group "Ejecucion EA"
input double          InpLots           = 0.10;
input ulong           InpMagicNumber    = 42020003;
input int             InpSlippagePoints = 30;
input string          InpComment        = "Adaptive_Regime_D1";

enum RegimeState
{
   REGIME_NEUTRAL = 0,
   REGIME_TREND   = 1,
   REGIME_RANGE   = 2
};

enum EntryEngine
{
   ENGINE_NONE   = 0,
   ENGINE_TREND  = 1,
   ENGINE_RANGE  = 2
};

int      g_emaFastHandle_Adaptive_Regime_D1 = INVALID_HANDLE;
int      g_emaSlowHandle_Adaptive_Regime_D1 = INVALID_HANDLE;
int      g_adxHandle_Adaptive_Regime_D1     = INVALID_HANDLE;
int      g_atrHandle_Adaptive_Regime_D1     = INVALID_HANDLE;
int      g_rsiHandle_Adaptive_Regime_D1     = INVALID_HANDLE;
int      g_bbHandle_Adaptive_Regime_D1      = INVALID_HANDLE;
datetime g_lastBarTime_Adaptive_Regime_D1   = 0;


double NormalizePrice_Adaptive_Regime_D1(const double price)
{
   return NormalizeDouble(price, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
}


double NormalizeLots_Adaptive_Regime_D1(const double lots)
{
   const double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   const double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0)
      return 0.0;

   double out = MathFloor(lots / step + 0.5) * step;
   out = MathMax(minLot, MathMin(maxLot, out));
   return out;
}


bool IsNewBar_Adaptive_Regime_D1()
{
   const datetime t0 = iTime(_Symbol, InpTimeframe, 0);
   if(t0 <= 0)
      return false;

   if(t0 != g_lastBarTime_Adaptive_Regime_D1)
   {
      g_lastBarTime_Adaptive_Regime_D1 = t0;
      return true;
   }
   return false;
}


bool CopyOne_Adaptive_Regime_D1(const int handle, const int buffer, const int shift, double &value)
{
   double data[1];
   if(CopyBuffer(handle, buffer, shift, 1, data) != 1)
      return false;
   value = data[0];
   return MathIsValidNumber(value);
}


double MinStopDistancePrice_Adaptive_Regime_D1()
{
   const double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0.0)
      return 0.0;

   const int stopLvl = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   const int freeze  = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   return MathMax(stopLvl, freeze) * point;
}


double ClampSL_Adaptive_Regime_D1(const long side, const double proposedSL)
{
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0)
      return 0.0;

   double sl = proposedSL;
   const double minDist = MinStopDistancePrice_Adaptive_Regime_D1();
   if(side == POSITION_TYPE_BUY)
      sl = MathMin(sl, bid - minDist);
   else
      sl = MathMax(sl, ask + minDist);

   return NormalizePrice_Adaptive_Regime_D1(sl);
}


bool ModifySLTPByTicket_Adaptive_Regime_D1(const ulong ticket, const double newSL, const double newTP)
{
   MqlTradeRequest request;
   MqlTradeResult  result;
   ZeroMemory(request);
   ZeroMemory(result);

   request.action   = TRADE_ACTION_SLTP;
   request.symbol   = _Symbol;
   request.position = ticket;
   request.sl       = newSL;
   request.tp       = newTP;
   request.magic    = InpMagicNumber;

   if(!OrderSend(request, result))
      return false;

   return (result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_DONE_PARTIAL);
}


bool GetMyPosition_Adaptive_Regime_D1(ulong &ticket, long &type, datetime &openTime, double &sl, double &tp, string &comment)
{
   const int total = PositionsTotal();
   for(int i = total - 1; i >= 0; --i)
   {
      const ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      ticket = t;
      type = PositionGetInteger(POSITION_TYPE);
      openTime = (datetime)PositionGetInteger(POSITION_TIME);
      sl = PositionGetDouble(POSITION_SL);
      tp = PositionGetDouble(POSITION_TP);
      comment = PositionGetString(POSITION_COMMENT);
      return true;
   }
   return false;
}


int BarsHeld_Adaptive_Regime_D1(const datetime openTime)
{
   const int shift = iBarShift(_Symbol, InpTimeframe, openTime, false);
   if(shift < 0)
      return 0;
   return shift;
}


EntryEngine ParseEngineFromComment_Adaptive_Regime_D1(const string comment)
{
   if(StringFind(comment, "|TREND") >= 0)
      return ENGINE_TREND;
   if(StringFind(comment, "|RANGE") >= 0)
      return ENGINE_RANGE;
   return ENGINE_NONE;
}


string BuildCommentByEngine_Adaptive_Regime_D1(const EntryEngine engine)
{
   if(engine == ENGINE_TREND)
      return InpComment + "|TREND";
   if(engine == ENGINE_RANGE)
      return InpComment + "|RANGE";
   return InpComment + "|UNKNOWN";
}


RegimeState DetectRegime_Adaptive_Regime_D1(const double adxPrev, const double bbWidthPrev)
{
   if(adxPrev >= InpADXTrend)
      return REGIME_TREND;
   if(adxPrev <= InpADXRange && bbWidthPrev <= InpRangeBBWMax)
      return REGIME_RANGE;
   return REGIME_NEUTRAL;
}


bool OpenPosition_Adaptive_Regime_D1(const int signal, const double atrPrev, const EntryEngine engine)
{
   if(signal != 1 && signal != -1)
      return false;
   if(atrPrev <= 0.0)
      return false;

   const double lots = NormalizeLots_Adaptive_Regime_D1(InpLots);
   if(lots <= 0.0)
      return false;

   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0)
      return false;

   trade_Adaptive_Regime_D1.SetExpertMagicNumber(InpMagicNumber);
   trade_Adaptive_Regime_D1.SetDeviationInPoints(InpSlippagePoints);

   const string cmt = BuildCommentByEngine_Adaptive_Regime_D1(engine);

   if(signal == 1)
   {
      const double slRaw = ask - (InpSL_ATR * atrPrev);
      const double sl = ClampSL_Adaptive_Regime_D1(POSITION_TYPE_BUY, slRaw);
      return trade_Adaptive_Regime_D1.Buy(lots, _Symbol, 0.0, sl, 0.0, cmt);
   }
   else
   {
      const double slRaw = bid + (InpSL_ATR * atrPrev);
      const double sl = ClampSL_Adaptive_Regime_D1(POSITION_TYPE_SELL, slRaw);
      return trade_Adaptive_Regime_D1.Sell(lots, _Symbol, 0.0, sl, 0.0, cmt);
   }
}


bool ClosePosition_Adaptive_Regime_D1(const ulong ticket)
{
   trade_Adaptive_Regime_D1.SetExpertMagicNumber(InpMagicNumber);
   trade_Adaptive_Regime_D1.SetDeviationInPoints(InpSlippagePoints);
   return trade_Adaptive_Regime_D1.PositionClose(ticket);
}


void UpdateTrailingStop_Adaptive_Regime_D1(const ulong ticket, const long side, const double currentSL, const double currentTP, const double atrPrev, const double closePrev)
{
   if(atrPrev <= 0.0 || closePrev <= 0.0)
      return;

   if(side == POSITION_TYPE_BUY)
   {
      const double desired = closePrev - (InpTrailATR * atrPrev);
      const double newSL = ClampSL_Adaptive_Regime_D1(POSITION_TYPE_BUY, desired);
      if(newSL > 0.0 && (currentSL == 0.0 || newSL > currentSL + (_Point * 0.5)))
         ModifySLTPByTicket_Adaptive_Regime_D1(ticket, newSL, currentTP);
   }
   else if(side == POSITION_TYPE_SELL)
   {
      const double desired = closePrev + (InpTrailATR * atrPrev);
      const double newSL = ClampSL_Adaptive_Regime_D1(POSITION_TYPE_SELL, desired);
      if(newSL > 0.0 && (currentSL == 0.0 || newSL < currentSL - (_Point * 0.5)))
         ModifySLTPByTicket_Adaptive_Regime_D1(ticket, newSL, currentTP);
   }
}


void ProcessOnNewDailyBar_Adaptive_Regime_D1()
{
   // Leemos todo en barra cerrada (shift=1) para inmunidad intrabar.
   double emaFast = 0.0, emaSlow = 0.0, adxMain = 0.0, atrPrev = 0.0, rsiPrev = 0.0;
   double bbMid = 0.0, bbUpper = 0.0, bbLower = 0.0;
   if(!CopyOne_Adaptive_Regime_D1(g_emaFastHandle_Adaptive_Regime_D1, 0, 1, emaFast))
      return;
   if(!CopyOne_Adaptive_Regime_D1(g_emaSlowHandle_Adaptive_Regime_D1, 0, 1, emaSlow))
      return;
   if(!CopyOne_Adaptive_Regime_D1(g_adxHandle_Adaptive_Regime_D1, 0, 1, adxMain))
      return;
   if(!CopyOne_Adaptive_Regime_D1(g_atrHandle_Adaptive_Regime_D1, 0, 1, atrPrev))
      return;
   if(!CopyOne_Adaptive_Regime_D1(g_rsiHandle_Adaptive_Regime_D1, 0, 1, rsiPrev))
      return;
   if(!CopyOne_Adaptive_Regime_D1(g_bbHandle_Adaptive_Regime_D1, 0, 1, bbMid))   // BASE_LINE
      return;
   if(!CopyOne_Adaptive_Regime_D1(g_bbHandle_Adaptive_Regime_D1, 1, 1, bbUpper)) // UPPER_BAND
      return;
   if(!CopyOne_Adaptive_Regime_D1(g_bbHandle_Adaptive_Regime_D1, 2, 1, bbLower)) // LOWER_BAND
      return;

   const double closePrev = iClose(_Symbol, InpTimeframe, 1);
   if(!MathIsValidNumber(closePrev) || closePrev <= 0.0 || bbMid <= 0.0)
      return;

   const double bbWidth = (bbUpper - bbLower) / bbMid;
   const RegimeState regime = DetectRegime_Adaptive_Regime_D1(adxMain, bbWidth);

   // ===== Motores aislados por estado =====
   bool trendLong = false, trendShort = false;
   bool rangeLong = false, rangeShort = false;

   if(regime == REGIME_TREND)
   {
      trendLong = (emaFast > emaSlow && closePrev > emaSlow);
      trendShort = (InpAllowShort && emaFast < emaSlow && closePrev < emaSlow && rsiPrev >= InpRSIHigh);
   }
   else if(regime == REGIME_RANGE)
   {
      rangeLong = (closePrev < bbLower && rsiPrev <= InpRSILow);
      rangeShort = (InpAllowShort && closePrev > bbUpper && rsiPrev >= InpRSIHigh);
   }

   const bool longSignal = trendLong || rangeLong;
   const bool shortSignal = trendShort || rangeShort;
   const EntryEngine desiredEngine = (regime == REGIME_TREND ? ENGINE_TREND : (regime == REGIME_RANGE ? ENGINE_RANGE : ENGINE_NONE));

   // Salidas de reversión (como en el prototipo Python).
   const bool exitLongBase = ((regime == REGIME_RANGE) && (closePrev >= bbMid)) || (rsiPrev >= 55.0);
   const bool exitShortBase = ((regime == REGIME_RANGE) && (closePrev <= bbMid)) || (rsiPrev <= 45.0);

   ulong ticket = 0;
   long side = -1;
   datetime openTime = 0;
   double currentSL = 0.0, currentTP = 0.0;
   string posComment = "";
   const bool hasPos = GetMyPosition_Adaptive_Regime_D1(ticket, side, openTime, currentSL, currentTP, posComment);

   if(hasPos)
   {
      const EntryEngine entryEngine = ParseEngineFromComment_Adaptive_Regime_D1(posComment);

      // Trailing diario siempre activo (bar-level, no intrabar).
      UpdateTrailingStop_Adaptive_Regime_D1(ticket, side, currentSL, currentTP, atrPrev, closePrev);

      // Time exit (hibrido de riesgo) replicando motor Python.
      const int heldBars = BarsHeld_Adaptive_Regime_D1(openTime);
      if(heldBars >= InpMaxHoldBars)
      {
         ClosePosition_Adaptive_Regime_D1(ticket);
         return;
      }

      // Salidas condicionadas por motor de entrada para evitar conflictos:
      // - Engine TREND: prioridad a trailing/opposite, pero mantiene RSI hard-stop.
      // - Engine RANGE: salida a media RSI/BB mas agresiva.
      bool shouldExit = false;
      if(side == POSITION_TYPE_BUY)
      {
         if(entryEngine == ENGINE_RANGE)
            shouldExit = exitLongBase;
         else if(entryEngine == ENGINE_TREND)
            shouldExit = (rsiPrev >= 60.0); // mas laxa que range, evita cortar tendencias temprano
         else
            shouldExit = exitLongBase;

         if(shortSignal)
            shouldExit = true;
      }
      else if(side == POSITION_TYPE_SELL)
      {
         if(entryEngine == ENGINE_RANGE)
            shouldExit = exitShortBase;
         else if(entryEngine == ENGINE_TREND)
            shouldExit = (rsiPrev <= 40.0);
         else
            shouldExit = exitShortBase;

         if(longSignal)
            shouldExit = true;
      }

      if(shouldExit)
      {
         if(ClosePosition_Adaptive_Regime_D1(ticket))
         {
            // Flip controlado solo si hay señal valida del estado actual.
            if(longSignal && desiredEngine != ENGINE_NONE)
               OpenPosition_Adaptive_Regime_D1(1, atrPrev, desiredEngine);
            else if(shortSignal && desiredEngine != ENGINE_NONE)
               OpenPosition_Adaptive_Regime_D1(-1, atrPrev, desiredEngine);
         }
         return;
      }
      return;
   }

   // Sin posicion: entra solo si hay señal de un motor activo.
   if(desiredEngine != ENGINE_NONE)
   {
      if(longSignal)
         OpenPosition_Adaptive_Regime_D1(1, atrPrev, desiredEngine);
      else if(shortSignal)
         OpenPosition_Adaptive_Regime_D1(-1, atrPrev, desiredEngine);
   }
}


int OnInit()
{
   g_emaFastHandle_Adaptive_Regime_D1 = iMA(_Symbol, InpTimeframe, InpEmaFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_emaSlowHandle_Adaptive_Regime_D1 = iMA(_Symbol, InpTimeframe, InpEmaSlowPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_adxHandle_Adaptive_Regime_D1     = iADX(_Symbol, InpTimeframe, InpADXPeriod);
   g_atrHandle_Adaptive_Regime_D1     = iATR(_Symbol, InpTimeframe, InpATRPeriod);
   g_rsiHandle_Adaptive_Regime_D1     = iRSI(_Symbol, InpTimeframe, InpRSIPeriod, PRICE_CLOSE);
   g_bbHandle_Adaptive_Regime_D1      = iBands(_Symbol, InpTimeframe, InpBBPeriod, 0, InpBBStdDev, PRICE_CLOSE);

   if(g_emaFastHandle_Adaptive_Regime_D1 == INVALID_HANDLE ||
      g_emaSlowHandle_Adaptive_Regime_D1 == INVALID_HANDLE ||
      g_adxHandle_Adaptive_Regime_D1 == INVALID_HANDLE ||
      g_atrHandle_Adaptive_Regime_D1 == INVALID_HANDLE ||
      g_rsiHandle_Adaptive_Regime_D1 == INVALID_HANDLE ||
      g_bbHandle_Adaptive_Regime_D1 == INVALID_HANDLE)
   {
      Print("Error al crear handles de indicadores.");
      return INIT_FAILED;
   }

   g_lastBarTime_Adaptive_Regime_D1 = iTime(_Symbol, InpTimeframe, 0);
   trade_Adaptive_Regime_D1.SetExpertMagicNumber(InpMagicNumber);
   trade_Adaptive_Regime_D1.SetDeviationInPoints(InpSlippagePoints);
   return INIT_SUCCEEDED;
}


void OnDeinit(const int reason)
{
   if(g_emaFastHandle_Adaptive_Regime_D1 != INVALID_HANDLE)
      IndicatorRelease(g_emaFastHandle_Adaptive_Regime_D1);
   if(g_emaSlowHandle_Adaptive_Regime_D1 != INVALID_HANDLE)
      IndicatorRelease(g_emaSlowHandle_Adaptive_Regime_D1);
   if(g_adxHandle_Adaptive_Regime_D1 != INVALID_HANDLE)
      IndicatorRelease(g_adxHandle_Adaptive_Regime_D1);
   if(g_atrHandle_Adaptive_Regime_D1 != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle_Adaptive_Regime_D1);
   if(g_rsiHandle_Adaptive_Regime_D1 != INVALID_HANDLE)
      IndicatorRelease(g_rsiHandle_Adaptive_Regime_D1);
   if(g_bbHandle_Adaptive_Regime_D1 != INVALID_HANDLE)
      IndicatorRelease(g_bbHandle_Adaptive_Regime_D1);
}


void OnTick()
{
   // Inmunidad a microestructura intradia: logica solo en apertura D1.
   if(!IsNewBar_Adaptive_Regime_D1())
      return;

   ProcessOnNewDailyBar_Adaptive_Regime_D1();
}
