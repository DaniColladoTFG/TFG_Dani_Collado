#property copyright "TFG Bot Trading"
#property version   "1.01"
#property strict

#include <Trade/Trade.mqh>

CTrade trade_Donchian_Definitiva_D1;

input group "Operativa"
input ENUM_TIMEFRAMES InpTimeframe_Donchian_Definitiva_D1           = PERIOD_D1;

input group "Senales Donchian"
input int             InpDonchianPeriod_Donchian_Definitiva_D1      = 20;
input int             InpEmaFilter_Donchian_Definitiva_D1           = 120;
input int             InpEmaSlopeLookback_Donchian_Definitiva_D1    = 5;

input group "Filtros volatilidad y regimen"
input int             InpATRPeriod_Donchian_Definitiva_D1           = 14;
input int             InpADXPeriod_Donchian_Definitiva_D1           = 10;
input double          InpADXThreshold_Donchian_Definitiva_D1        = 18.0;
input double          InpShortExtraADX_Donchian_Definitiva_D1       = 12.0;
input int             InpBBPeriod_Donchian_Definitiva_D1            = 20;
input double          InpMinBBWidth_Donchian_Definitiva_D1          = 0.012;
input double          InpMinATRPct_Donchian_Definitiva_D1           = 0.0040;

input group "Salidas y riesgo"
input double          InpSL_ATR_Donchian_Definitiva_D1              = 2.0;
input double          InpTrailATR_Donchian_Definitiva_D1            = 3.0;
input double          InpBreakEvenATRTrigger_Donchian_Definitiva_D1   = 1.0;
input double          InpBreakEvenOffset_Donchian_Definitiva_D1     = 0.5;
input int             InpMaxHoldBars_Donchian_Definitiva_D1         = 90;
input bool            InpAllowShort_Donchian_Definitiva_D1          = false;

input group "Gestion monetaria"
input double          InpRiskPercent_Donchian_Definitiva_D1         = 4.0;
input double          InpMaxLots_Donchian_Definitiva_D1             = 0.75;
input double          InpMinLots_Donchian_Definitiva_D1             = 0.01;

input group "Ejecucion EA"
input ulong           InpMagicNumber_Donchian_Definitiva_D1         = 10001001;
input int             InpSlippagePoints_Donchian_Definitiva_D1      = 30;
input string          InpComment_Donchian_Definitiva_D1             = "Donchian_Definitiva_D1";

int      g_emaHandle_Donchian_Definitiva_D1  = INVALID_HANDLE;
int      g_atrHandle_Donchian_Definitiva_D1  = INVALID_HANDLE;
int      g_adxHandle_Donchian_Definitiva_D1  = INVALID_HANDLE;
int      g_bbHandle_Donchian_Definitiva_D1   = INVALID_HANDLE;
datetime g_lastBarTime_Donchian_Definitiva_D1 = 0;


double NormalizePrice_Donchian_Definitiva_D1(const double price)
{
   const int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   return NormalizeDouble(price, digits);
}


double NormalizeLots_Donchian_Definitiva_D1(const double lots)
{
   const double brokerMin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double brokerMax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   const double step      = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0)
      return 0.0;

   const double minLot = MathMax(InpMinLots_Donchian_Definitiva_D1, brokerMin);
   const double maxLot = MathMin(InpMaxLots_Donchian_Definitiva_D1, brokerMax);
   if(maxLot < minLot)
      return 0.0;

   double v = MathFloor(lots / step) * step;
   v = MathMax(minLot, MathMin(maxLot, v));
   return NormalizeDouble(v, 2);
}


bool IsNewBar_Donchian_Definitiva_D1()
{
   const datetime barTime = iTime(_Symbol, InpTimeframe_Donchian_Definitiva_D1, 0);
   if(barTime <= 0)
      return false;

   if(barTime != g_lastBarTime_Donchian_Definitiva_D1)
   {
      g_lastBarTime_Donchian_Definitiva_D1 = barTime;
      return true;
   }
   return false;
}


bool CopyOne_Donchian_Definitiva_D1(const int handle, const int bufferIdx, const int shift, double &value)
{
   double data[1];
   if(CopyBuffer(handle, bufferIdx, shift, 1, data) != 1)
      return false;
   value = data[0];
   return MathIsValidNumber(value);
}


bool GetDonchianPrev_Donchian_Definitiva_D1(const int period, double &upperPrev, double &lowerPrev)
{
   if(period <= 0)
      return false;

   double highs[];
   double lows[];
   ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows, true);

   if(CopyHigh(_Symbol, InpTimeframe_Donchian_Definitiva_D1, 2, period, highs) != period)
      return false;
   if(CopyLow(_Symbol, InpTimeframe_Donchian_Definitiva_D1, 2, period, lows) != period)
      return false;

   upperPrev = highs[0];
   lowerPrev = lows[0];
   for(int i = 1; i < period; i++)
   {
      if(highs[i] > upperPrev)
         upperPrev = highs[i];
      if(lows[i] < lowerPrev)
         lowerPrev = lows[i];
   }
   return true;
}


bool GetBBWidthPrev_Donchian_Definitiva_D1(double &width)
{
   double bbMid = 0.0, bbUpper = 0.0, bbLower = 0.0;
   if(!CopyOne_Donchian_Definitiva_D1(g_bbHandle_Donchian_Definitiva_D1, 0, 1, bbMid))
      return false;
   if(!CopyOne_Donchian_Definitiva_D1(g_bbHandle_Donchian_Definitiva_D1, 1, 1, bbUpper))
      return false;
   if(!CopyOne_Donchian_Definitiva_D1(g_bbHandle_Donchian_Definitiva_D1, 2, 1, bbLower))
      return false;
   if(bbMid <= 0.0)
      return false;

   width = (bbUpper - bbLower) / bbMid;
   return MathIsValidNumber(width);
}


bool GetMyPosition_Donchian_Definitiva_D1(
   ulong &ticket,
   long &type,
   datetime &openTime,
   double &openPrice,
   double &sl,
   double &tp
)
{
   const int total = PositionsTotal();
   for(int i = total - 1; i >= 0; --i)
   {
      const ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber_Donchian_Definitiva_D1)
         continue;

      ticket = t;
      type = PositionGetInteger(POSITION_TYPE);
      openTime = (datetime)PositionGetInteger(POSITION_TIME);
      openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      sl = PositionGetDouble(POSITION_SL);
      tp = PositionGetDouble(POSITION_TP);
      return true;
   }
   return false;
}


int BarsHeld_Donchian_Definitiva_D1(const datetime openTime)
{
   const int shift = iBarShift(_Symbol, InpTimeframe_Donchian_Definitiva_D1, openTime, false);
   if(shift < 0)
      return 0;
   return shift;
}


double MinStopDistancePrice_Donchian_Definitiva_D1()
{
   const double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0.0)
      return 0.0;

   const int stopLvl = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   const int freeze  = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   const int distPts = MathMax(stopLvl, freeze);
   return distPts * point;
}


double ClampSLToBroker_Donchian_Definitiva_D1(const long posType, const double proposedSL)
{
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0)
      return 0.0;

   const double minDist = MinStopDistancePrice_Donchian_Definitiva_D1();
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

   return NormalizePrice_Donchian_Definitiva_D1(sl);
}


bool ModifySLTPByTicket_Donchian_Definitiva_D1(const ulong ticket, const double sl, const double tp)
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
   request.magic    = InpMagicNumber_Donchian_Definitiva_D1;

   if(!OrderSend(request, result))
      return false;

   return (result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_DONE_PARTIAL);
}


double ComputeRiskLots_Donchian_Definitiva_D1(const double entryPrice, const double stopPrice)
{
   const double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity <= 0.0 || InpRiskPercent_Donchian_Definitiva_D1 <= 0.0)
      return 0.0;

   const double stopDistance = MathAbs(entryPrice - stopPrice);
   if(stopDistance <= 0.0)
      return 0.0;

   const double contractSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   if(contractSize <= 0.0)
      return 0.0;

   const double riskMoney = equity * (InpRiskPercent_Donchian_Definitiva_D1 / 100.0);
   const double moneyPerLot = stopDistance * contractSize;
   if(moneyPerLot <= 0.0)
      return 0.0;

   const double rawLots = riskMoney / moneyPerLot;
   return NormalizeLots_Donchian_Definitiva_D1(rawLots);
}


bool OpenPosition_Donchian_Definitiva_D1(const int signal, const double atrPrev)
{
   if(signal != 1 && signal != -1)
      return false;
   if(atrPrev <= 0.0)
      return false;

   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0)
      return false;

   trade_Donchian_Definitiva_D1.SetExpertMagicNumber(InpMagicNumber_Donchian_Definitiva_D1);
   trade_Donchian_Definitiva_D1.SetDeviationInPoints(InpSlippagePoints_Donchian_Definitiva_D1);

   if(signal == 1)
   {
      const double desiredSL = ask - (InpSL_ATR_Donchian_Definitiva_D1 * atrPrev);
      const double sl = ClampSLToBroker_Donchian_Definitiva_D1(POSITION_TYPE_BUY, desiredSL);
      if(sl <= 0.0)
         return false;

      const double lots = ComputeRiskLots_Donchian_Definitiva_D1(ask, sl);
      if(lots <= 0.0)
         return false;
      return trade_Donchian_Definitiva_D1.Buy(lots, _Symbol, 0.0, sl, 0.0, InpComment_Donchian_Definitiva_D1);
   }

   const double desiredSL = bid + (InpSL_ATR_Donchian_Definitiva_D1 * atrPrev);
   const double sl = ClampSLToBroker_Donchian_Definitiva_D1(POSITION_TYPE_SELL, desiredSL);
   if(sl <= 0.0)
      return false;

   const double lots = ComputeRiskLots_Donchian_Definitiva_D1(bid, sl);
   if(lots <= 0.0)
      return false;
   return trade_Donchian_Definitiva_D1.Sell(lots, _Symbol, 0.0, sl, 0.0, InpComment_Donchian_Definitiva_D1);
}


bool ClosePositionByTicket_Donchian_Definitiva_D1(const ulong ticket)
{
   trade_Donchian_Definitiva_D1.SetExpertMagicNumber(InpMagicNumber_Donchian_Definitiva_D1);
   trade_Donchian_Definitiva_D1.SetDeviationInPoints(InpSlippagePoints_Donchian_Definitiva_D1);
   return trade_Donchian_Definitiva_D1.PositionClose(ticket);
}


void UpdateStops_Donchian_Definitiva_D1(
   const ulong ticket,
   const long posType,
   const double openPrice,
   const double currentSL,
   const double currentTP,
   const double atrPrev,
   const double closePrev
)
{
   if(atrPrev <= 0.0 || closePrev <= 0.0 || openPrice <= 0.0)
      return;

   if(posType == POSITION_TYPE_BUY)
   {
      double desiredSL = currentSL;

      const double beTriggerPrice = openPrice + (InpBreakEvenATRTrigger_Donchian_Definitiva_D1 * atrPrev);
      if(closePrev >= beTriggerPrice)
      {
         const double beSL = openPrice + InpBreakEvenOffset_Donchian_Definitiva_D1;
         if(currentSL == 0.0 || beSL > desiredSL)
            desiredSL = beSL;
      }

      const double trailingSL = closePrev - (InpTrailATR_Donchian_Definitiva_D1 * atrPrev);
      if(currentSL == 0.0 || trailingSL > desiredSL)
         desiredSL = trailingSL;

      const double newSL = ClampSLToBroker_Donchian_Definitiva_D1(POSITION_TYPE_BUY, desiredSL);
      if(newSL > 0.0 && (currentSL == 0.0 || newSL > currentSL + (_Point * 0.5)))
         ModifySLTPByTicket_Donchian_Definitiva_D1(ticket, newSL, currentTP);
   }
   else if(posType == POSITION_TYPE_SELL)
   {
      double desiredSL = currentSL;

      const double beTriggerPrice = openPrice - (InpBreakEvenATRTrigger_Donchian_Definitiva_D1 * atrPrev);
      if(closePrev <= beTriggerPrice)
      {
         const double beSL = openPrice - InpBreakEvenOffset_Donchian_Definitiva_D1;
         if(currentSL == 0.0 || beSL < desiredSL)
            desiredSL = beSL;
      }

      const double trailingSL = closePrev + (InpTrailATR_Donchian_Definitiva_D1 * atrPrev);
      if(currentSL == 0.0 || trailingSL < desiredSL)
         desiredSL = trailingSL;

      const double newSL = ClampSLToBroker_Donchian_Definitiva_D1(POSITION_TYPE_SELL, desiredSL);
      if(newSL > 0.0 && (currentSL == 0.0 || newSL < currentSL - (_Point * 0.5)))
         ModifySLTPByTicket_Donchian_Definitiva_D1(ticket, newSL, currentTP);
   }
}


void ProcessNewDailyBar_Donchian_Definitiva_D1()
{
   double emaPrev = 0.0, emaSlopeRef = 0.0, atrPrev = 0.0, adxPrev = 0.0;
   if(!CopyOne_Donchian_Definitiva_D1(g_emaHandle_Donchian_Definitiva_D1, 0, 1, emaPrev))
      return;
   if(!CopyOne_Donchian_Definitiva_D1(g_emaHandle_Donchian_Definitiva_D1, 0, 1 + InpEmaSlopeLookback_Donchian_Definitiva_D1, emaSlopeRef))
      return;
   if(!CopyOne_Donchian_Definitiva_D1(g_atrHandle_Donchian_Definitiva_D1, 0, 1, atrPrev))
      return;
   if(!CopyOne_Donchian_Definitiva_D1(g_adxHandle_Donchian_Definitiva_D1, 0, 1, adxPrev))
      return;

   const double closePrev = iClose(_Symbol, InpTimeframe_Donchian_Definitiva_D1, 1);
   if(!MathIsValidNumber(closePrev) || closePrev <= 0.0)
      return;

   double donHighPrev = 0.0, donLowPrev = 0.0;
   if(!GetDonchianPrev_Donchian_Definitiva_D1(InpDonchianPeriod_Donchian_Definitiva_D1, donHighPrev, donLowPrev))
      return;

   double bbWidthPrev = 0.0;
   if(!GetBBWidthPrev_Donchian_Definitiva_D1(bbWidthPrev))
      return;

   const double emaSlope = emaPrev - emaSlopeRef;
   const bool trendOK = (adxPrev >= InpADXThreshold_Donchian_Definitiva_D1) &&
                        ((atrPrev / closePrev) >= InpMinATRPct_Donchian_Definitiva_D1) &&
                        (bbWidthPrev >= InpMinBBWidth_Donchian_Definitiva_D1);

   const bool longSignal = trendOK &&
                           (closePrev > donHighPrev) &&
                           (closePrev > emaPrev) &&
                           (emaSlope > 0.0);

   const bool shortSignal = InpAllowShort_Donchian_Definitiva_D1 &&
                            trendOK &&
                            (closePrev < donLowPrev) &&
                            (closePrev < emaPrev) &&
                            (emaSlope < 0.0) &&
                            (adxPrev >= (InpADXThreshold_Donchian_Definitiva_D1 + InpShortExtraADX_Donchian_Definitiva_D1));

   ulong ticket = 0;
   long posType = -1;
   datetime openTime = 0;
   double openPrice = 0.0, posSL = 0.0, posTP = 0.0;
   const bool hasPos = GetMyPosition_Donchian_Definitiva_D1(ticket, posType, openTime, openPrice, posSL, posTP);

   if(hasPos)
   {
      UpdateStops_Donchian_Definitiva_D1(ticket, posType, openPrice, posSL, posTP, atrPrev, closePrev);

      const int heldBars = BarsHeld_Donchian_Definitiva_D1(openTime);
      if(heldBars >= InpMaxHoldBars_Donchian_Definitiva_D1)
      {
         ClosePositionByTicket_Donchian_Definitiva_D1(ticket);
         return;
      }

      const bool oppositeSignal = (posType == POSITION_TYPE_BUY && shortSignal) ||
                                  (posType == POSITION_TYPE_SELL && longSignal);
      if(oppositeSignal)
      {
         if(ClosePositionByTicket_Donchian_Definitiva_D1(ticket))
         {
            if(longSignal)
               OpenPosition_Donchian_Definitiva_D1(1, atrPrev);
            else if(shortSignal)
               OpenPosition_Donchian_Definitiva_D1(-1, atrPrev);
         }
      }
      return;
   }

   if(longSignal)
      OpenPosition_Donchian_Definitiva_D1(1, atrPrev);
   else if(shortSignal)
      OpenPosition_Donchian_Definitiva_D1(-1, atrPrev);
}


int OnInit()
{
   g_emaHandle_Donchian_Definitiva_D1 = iMA(_Symbol, InpTimeframe_Donchian_Definitiva_D1, InpEmaFilter_Donchian_Definitiva_D1, 0, MODE_EMA, PRICE_CLOSE);
   g_atrHandle_Donchian_Definitiva_D1 = iATR(_Symbol, InpTimeframe_Donchian_Definitiva_D1, InpATRPeriod_Donchian_Definitiva_D1);
   g_adxHandle_Donchian_Definitiva_D1 = iADX(_Symbol, InpTimeframe_Donchian_Definitiva_D1, InpADXPeriod_Donchian_Definitiva_D1);
   g_bbHandle_Donchian_Definitiva_D1  = iBands(_Symbol, InpTimeframe_Donchian_Definitiva_D1, InpBBPeriod_Donchian_Definitiva_D1, 0, 2.0, PRICE_CLOSE);

   if(g_emaHandle_Donchian_Definitiva_D1 == INVALID_HANDLE ||
      g_atrHandle_Donchian_Definitiva_D1 == INVALID_HANDLE ||
      g_adxHandle_Donchian_Definitiva_D1 == INVALID_HANDLE ||
      g_bbHandle_Donchian_Definitiva_D1 == INVALID_HANDLE)
   {
      Print("Error al crear handles de indicadores.");
      return INIT_FAILED;
   }

   g_lastBarTime_Donchian_Definitiva_D1 = iTime(_Symbol, InpTimeframe_Donchian_Definitiva_D1, 0);
   trade_Donchian_Definitiva_D1.SetExpertMagicNumber(InpMagicNumber_Donchian_Definitiva_D1);
   trade_Donchian_Definitiva_D1.SetDeviationInPoints(InpSlippagePoints_Donchian_Definitiva_D1);
   return INIT_SUCCEEDED;
}


void OnDeinit(const int reason)
{
   if(g_emaHandle_Donchian_Definitiva_D1 != INVALID_HANDLE)
      IndicatorRelease(g_emaHandle_Donchian_Definitiva_D1);
   if(g_atrHandle_Donchian_Definitiva_D1 != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle_Donchian_Definitiva_D1);
   if(g_adxHandle_Donchian_Definitiva_D1 != INVALID_HANDLE)
      IndicatorRelease(g_adxHandle_Donchian_Definitiva_D1);
   if(g_bbHandle_Donchian_Definitiva_D1 != INVALID_HANDLE)
      IndicatorRelease(g_bbHandle_Donchian_Definitiva_D1);
}


void OnTick()
{
   if(!IsNewBar_Donchian_Definitiva_D1())
      return;

   ProcessNewDailyBar_Donchian_Definitiva_D1();
}
