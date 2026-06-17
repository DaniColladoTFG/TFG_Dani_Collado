#property copyright "TFG Bot Trading"
#property version   "1.02"
#property strict

#include <Trade/Trade.mqh>

CTrade trade_Donchian_Breakout_D1;

input group "Operativa"
input ENUM_TIMEFRAMES InpTimeframe      = PERIOD_D1;

input group "Señales Donchian"
input int             InpDonchianPeriod = 20;
input int             InpEmaFilter      = 200;
input int             InpATRPeriod      = 10;
input int             InpADXPeriod      = 10;
input double          InpADXThreshold   = 18.0;

input group "Salidas y riesgo"
input double          InpSL_ATR         = 1.5;
input double          InpTrailATR       = 2.0;
input int             InpMaxHoldBars    = 30;
input bool            InpAllowShort     = true;

input group "Ejecución EA"
input double          InpLots           = 0.10;
input ulong           InpMagicNumber    = 42020001;
input int             InpSlippagePoints = 30;
input string          InpComment        = "Donchian_Breakout_D1";

int      g_emaHandle_Donchian_Breakout_D1 = INVALID_HANDLE;
int      g_atrHandle_Donchian_Breakout_D1 = INVALID_HANDLE;
int      g_adxHandle_Donchian_Breakout_D1 = INVALID_HANDLE;
datetime g_lastBarTime_Donchian_Breakout_D1 = 0;


double NormalizePrice_Donchian_Breakout_D1(const double price)
{
   const int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   return NormalizeDouble(price, digits);
}


double NormalizeLots_Donchian_Breakout_D1(const double lots)
{
   const double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   const double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0)
      return 0.0;

   double v = MathFloor(lots / step + 0.5) * step;
   v = MathMax(minLot, MathMin(maxLot, v));
   return v;
}


bool IsNewBar_Donchian_Breakout_D1()
{
   const datetime barTime = iTime(_Symbol, InpTimeframe, 0);
   if(barTime <= 0)
      return false;

   if(barTime != g_lastBarTime_Donchian_Breakout_D1)
   {
      g_lastBarTime_Donchian_Breakout_D1 = barTime;
      return true;
   }
   return false;
}


bool CopyOne_Donchian_Breakout_D1(const int handle, const int bufferIdx, const int shift, double &value)
{
   double data[1];
   if(CopyBuffer(handle, bufferIdx, shift, 1, data) != 1)
      return false;
   value = data[0];
   return MathIsValidNumber(value);
}


bool GetDonchianPrev_Donchian_Breakout_D1(const int period_Donchian_Breakout_D1, double &upperPrev, double &lowerPrev)
{
   if(period_Donchian_Breakout_D1 <= 0)
      return false;

   double highs[];
   double lows[];
   ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows, true);

   // Para señal en barra cerrada (shift=1), el canal usa barras [2 .. period_Donchian_Breakout_D1+1].
   if(CopyHigh(_Symbol, InpTimeframe, 2, period_Donchian_Breakout_D1, highs) != period_Donchian_Breakout_D1)
      return false;
   if(CopyLow(_Symbol, InpTimeframe, 2, period_Donchian_Breakout_D1, lows) != period_Donchian_Breakout_D1)
      return false;

   upperPrev = highs[0];
   lowerPrev = lows[0];
   for(int i = 1; i < period_Donchian_Breakout_D1; i++)
   {
      if(highs[i] > upperPrev)
         upperPrev = highs[i];
      if(lows[i] < lowerPrev)
         lowerPrev = lows[i];
   }
   return true;
}


bool GetMyPosition_Donchian_Breakout_D1(ulong &ticket, long &type, datetime &openTime, double &sl, double &tp)
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
      return true;
   }
   return false;
}


int BarsHeld_Donchian_Breakout_D1(const datetime openTime)
{
   const int shift = iBarShift(_Symbol, InpTimeframe, openTime, false);
   if(shift < 0)
      return 0;
   return shift;
}


double MinStopDistancePrice_Donchian_Breakout_D1()
{
   const double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0.0)
      return 0.0;

   // Equivalente MQL5 del MODE_STOPLEVEL (+ freeze).
   const int stopLvl = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   const int freeze  = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   const int distPts = MathMax(stopLvl, freeze);
   return distPts * point;
}


double ClampSLToBroker_Donchian_Breakout_D1(const long posType, const double proposedSL)
{
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0)
      return 0.0;

   const double minDist = MinStopDistancePrice_Donchian_Breakout_D1();
   double sl = proposedSL;

   if(posType == POSITION_TYPE_BUY)
   {
      const double maxSL = bid - minDist;
      sl = MathMin(sl, maxSL);
   }
   else if(posType == POSITION_TYPE_SELL)
   {
      const double minSL = ask + minDist;
      sl = MathMax(sl, minSL);
   }

   return NormalizePrice_Donchian_Breakout_D1(sl);
}


bool ModifySLTPByTicket_Donchian_Breakout_D1(const ulong ticket, const double sl, const double tp)
{
   MqlTradeRequest request;
   MqlTradeResult  result;
   ZeroMemory(request);
   ZeroMemory(result);

   request.action   = TRADE_ACTION_SLTP;
   request.symbol   = _Symbol;
   request.position = ticket;
   request.sl       = sl;
   request.tp       = tp;
   request.magic    = InpMagicNumber;

   if(!OrderSend(request, result))
      return false;

   return (result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_DONE_PARTIAL);
}


bool OpenPosition_Donchian_Breakout_D1(const int signal, const double atrPrev)
{
   if(signal != 1 && signal != -1)
      return false;
   if(atrPrev <= 0.0)
      return false;

   const double lots = NormalizeLots_Donchian_Breakout_D1(InpLots);
   if(lots <= 0.0)
      return false;

   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0)
      return false;

   trade_Donchian_Breakout_D1.SetExpertMagicNumber(InpMagicNumber);
   trade_Donchian_Breakout_D1.SetDeviationInPoints(InpSlippagePoints);

   if(signal == 1)
   {
      const double desiredSL = ask - (InpSL_ATR * atrPrev);
      const double sl = ClampSLToBroker_Donchian_Breakout_D1(POSITION_TYPE_BUY, desiredSL);
      return trade_Donchian_Breakout_D1.Buy(lots, _Symbol, 0.0, sl, 0.0, InpComment);
   }
   else
   {
      const double desiredSL = bid + (InpSL_ATR * atrPrev);
      const double sl = ClampSLToBroker_Donchian_Breakout_D1(POSITION_TYPE_SELL, desiredSL);
      return trade_Donchian_Breakout_D1.Sell(lots, _Symbol, 0.0, sl, 0.0, InpComment);
   }
}


bool ClosePositionByTicket_Donchian_Breakout_D1(const ulong ticket)
{
   trade_Donchian_Breakout_D1.SetExpertMagicNumber(InpMagicNumber);
   trade_Donchian_Breakout_D1.SetDeviationInPoints(InpSlippagePoints);
   return trade_Donchian_Breakout_D1.PositionClose(ticket);
}


void UpdateTrailingStop_Donchian_Breakout_D1(const ulong ticket, const long posType, const double currentSL, const double currentTP, const double atrPrev, const double closePrev)
{
   if(atrPrev <= 0.0 || closePrev <= 0.0)
      return;

   if(posType == POSITION_TYPE_BUY)
   {
      const double desired = closePrev - (InpTrailATR * atrPrev);
      const double newSL = ClampSLToBroker_Donchian_Breakout_D1(POSITION_TYPE_BUY, desired);
      if(newSL > 0.0 && (currentSL == 0.0 || newSL > currentSL + (_Point * 0.5)))
         ModifySLTPByTicket_Donchian_Breakout_D1(ticket, newSL, currentTP);
   }
   else if(posType == POSITION_TYPE_SELL)
   {
      const double desired = closePrev + (InpTrailATR * atrPrev);
      const double newSL = ClampSLToBroker_Donchian_Breakout_D1(POSITION_TYPE_SELL, desired);
      if(newSL > 0.0 && (currentSL == 0.0 || newSL < currentSL - (_Point * 0.5)))
         ModifySLTPByTicket_Donchian_Breakout_D1(ticket, newSL, currentTP);
   }
}


void ProcessNewDailyBar_Donchian_Breakout_D1()
{
   double emaPrev = 0.0, atrPrev = 0.0, adxPrev = 0.0;
   if(!CopyOne_Donchian_Breakout_D1(g_emaHandle_Donchian_Breakout_D1, 0, 1, emaPrev))
      return;
   if(!CopyOne_Donchian_Breakout_D1(g_atrHandle_Donchian_Breakout_D1, 0, 1, atrPrev))
      return;
   if(!CopyOne_Donchian_Breakout_D1(g_adxHandle_Donchian_Breakout_D1, 0, 1, adxPrev))
      return; // ADX main line buffer 0

   const double closePrev = iClose(_Symbol, InpTimeframe, 1);
   if(!MathIsValidNumber(closePrev) || closePrev <= 0.0)
      return;

   double donHighPrev = 0.0, donLowPrev = 0.0;
   if(!GetDonchianPrev_Donchian_Breakout_D1(InpDonchianPeriod, donHighPrev, donLowPrev))
      return;

   const bool longSignal = (closePrev > donHighPrev && closePrev > emaPrev && adxPrev >= InpADXThreshold);
   const bool shortSignal = (InpAllowShort && closePrev < donLowPrev && closePrev < emaPrev && adxPrev >= InpADXThreshold);

   ulong ticket = 0;
   long posType = -1;
   datetime openTime = 0;
   double posSL = 0.0, posTP = 0.0;
   const bool hasPos = GetMyPosition_Donchian_Breakout_D1(ticket, posType, openTime, posSL, posTP);

   if(hasPos)
   {
      // Trailing ATR solo en nueva vela D1 y solo en direccion favorable.
      UpdateTrailingStop_Donchian_Breakout_D1(ticket, posType, posSL, posTP, atrPrev, closePrev);

      const int heldBars = BarsHeld_Donchian_Breakout_D1(openTime);
      if(heldBars >= InpMaxHoldBars)
      {
         ClosePositionByTicket_Donchian_Breakout_D1(ticket);
         return; // Regla de tiempo prioritaria (no flip en la misma barra).
      }

      const bool oppositeSignal = (posType == POSITION_TYPE_BUY && shortSignal) || (posType == POSITION_TYPE_SELL && longSignal);
      if(oppositeSignal)
      {
         if(ClosePositionByTicket_Donchian_Breakout_D1(ticket))
         {
            if(longSignal)
               OpenPosition_Donchian_Breakout_D1(1, atrPrev);
            else if(shortSignal)
               OpenPosition_Donchian_Breakout_D1(-1, atrPrev);
         }
         return;
      }
      return;
   }

   if(longSignal)
      OpenPosition_Donchian_Breakout_D1(1, atrPrev);
   else if(shortSignal)
      OpenPosition_Donchian_Breakout_D1(-1, atrPrev);
}


int OnInit()
{
   g_emaHandle_Donchian_Breakout_D1 = iMA(_Symbol, InpTimeframe, InpEmaFilter, 0, MODE_EMA, PRICE_CLOSE);
   g_atrHandle_Donchian_Breakout_D1 = iATR(_Symbol, InpTimeframe, InpATRPeriod);
   g_adxHandle_Donchian_Breakout_D1 = iADX(_Symbol, InpTimeframe, InpADXPeriod);

   if(g_emaHandle_Donchian_Breakout_D1 == INVALID_HANDLE || g_atrHandle_Donchian_Breakout_D1 == INVALID_HANDLE || g_adxHandle_Donchian_Breakout_D1 == INVALID_HANDLE)
   {
      Print("Error al crear handles de indicadores.");
      return INIT_FAILED;
   }

   g_lastBarTime_Donchian_Breakout_D1 = iTime(_Symbol, InpTimeframe, 0);
   trade_Donchian_Breakout_D1.SetExpertMagicNumber(InpMagicNumber);
   trade_Donchian_Breakout_D1.SetDeviationInPoints(InpSlippagePoints);
   return INIT_SUCCEEDED;
}


void OnDeinit(const int reason)
{
   if(g_emaHandle_Donchian_Breakout_D1 != INVALID_HANDLE)
      IndicatorRelease(g_emaHandle_Donchian_Breakout_D1);
   if(g_atrHandle_Donchian_Breakout_D1 != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle_Donchian_Breakout_D1);
   if(g_adxHandle_Donchian_Breakout_D1 != INVALID_HANDLE)
      IndicatorRelease(g_adxHandle_Donchian_Breakout_D1);
}


void OnTick()
{
   // Control vital: solo evaluamos logica en apertura de nueva vela D1.
   if(!IsNewBar_Donchian_Breakout_D1())
      return;

   ProcessNewDailyBar_Donchian_Breakout_D1();
}
