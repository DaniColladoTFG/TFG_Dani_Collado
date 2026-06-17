#property copyright "TFG Bot Trading"
#property version   "1.00"
#property description "Estrategia4d - Donchian Fusion D1 (TREND-only, anti-churn)"
#property strict

#include <Trade/Trade.mqh>

CTrade trade_Donchian_Fusion_D1;

enum EntryMode4d
{
   ENTRY_FUSION_4B     = 0,
   ENTRY_REGIME_ADAPT  = 1
};

input group "Identificacion TFG (no optimizar)"
input string          InpBuildTag              = "4d_baseline";

input group "Operativa"
input ENUM_TIMEFRAMES InpTimeframe           = PERIOD_D1;
input EntryMode4d     InpEntryMode           = ENTRY_FUSION_4B;
input bool            InpUseRangeEngine      = false;

input group "Motor TREND fusion (estilo 4b)"
input int             InpDonchianPeriod      = 15;
input int             InpEmaFilterPeriod     = 100;
input bool            InpRequireEmaFilter    = true;
input int             InpADXPeriod           = 10;
input double          InpADXEntryMin         = 20.0;

input group "Motor TREND regimen (solo ENTRY_REGIME_ADAPT)"
input int             InpEmaFastPeriod       = 20;
input int             InpEmaSlowPeriod       = 100;
input bool            InpUseDonchianConfirm  = true;
input double          InpADXTrend            = 24.0;
input int             InpMinRegimeBars       = 1;

input group "Detector RANGE (solo si UseRangeEngine)"
input double          InpADXRange            = 16.0;
input int             InpBBPeriod            = 40;
input double          InpBBStdDev            = 2.2;
input double          InpRangeBBWMax         = 0.035;
input int             InpRSIPeriod           = 7;
input double          InpRSILow              = 25.0;
input double          InpRSIHigh             = 80.0;
input double          InpExitRSILongRange    = 55.0;
input double          InpExitRSIShortRange   = 45.0;

input group "Salidas y riesgo"
input int             InpATRPeriod           = 10;
input double          InpSL_ATR              = 2.5;
input double          InpTrailATR            = 2.0;
input int             InpMaxHoldBars         = 20;
input int             InpMinBarsBetweenEntries = 2;
input bool            InpAllowShort          = false;

input group "Ejecucion EA"
input double          InpLots                = 0.10;
input ulong           InpMagicNumber         = 42020004;
input int             InpSlippagePoints      = 30;
input string          InpComment             = "Donchian_Fusion_D1";

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

int      g_emaFastHandle_Donchian_Fusion_D1 = INVALID_HANDLE;
int      g_emaFilterHandle_Donchian_Fusion_D1 = INVALID_HANDLE;
int      g_adxHandle_Donchian_Fusion_D1     = INVALID_HANDLE;
int      g_atrHandle_Donchian_Fusion_D1     = INVALID_HANDLE;
int      g_rsiHandle_Donchian_Fusion_D1     = INVALID_HANDLE;
int      g_bbHandle_Donchian_Fusion_D1      = INVALID_HANDLE;
datetime g_lastBarTime_Donchian_Fusion_D1   = 0;
datetime g_lastClosedBarTime_Donchian_Fusion_D1 = 0;


double NormalizePrice_Donchian_Fusion_D1(const double price)
{
   return NormalizeDouble(price, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
}


double NormalizeLots_Donchian_Fusion_D1(const double lots)
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


bool IsNewBar_Donchian_Fusion_D1()
{
   const datetime t0 = iTime(_Symbol, InpTimeframe, 0);
   if(t0 <= 0)
      return false;

   if(t0 != g_lastBarTime_Donchian_Fusion_D1)
   {
      g_lastBarTime_Donchian_Fusion_D1 = t0;
      return true;
   }
   return false;
}


bool CopyOne_Donchian_Fusion_D1(const int handle, const int buffer, const int shift, double &value)
{
   double data[1];
   if(CopyBuffer(handle, buffer, shift, 1, data) != 1)
      return false;
   value = data[0];
   return MathIsValidNumber(value);
}


bool GetDonchianPrev_Donchian_Fusion_D1(const int period, double &upperPrev, double &lowerPrev)
{
   if(period <= 0)
      return false;

   double highs[];
   double lows[];
   ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows, true);

   if(CopyHigh(_Symbol, InpTimeframe, 2, period, highs) != period)
      return false;
   if(CopyLow(_Symbol, InpTimeframe, 2, period, lows) != period)
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


double MinStopDistancePrice_Donchian_Fusion_D1()
{
   const double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0.0)
      return 0.0;

   const int stopLvl = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   const int freeze  = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   return MathMax(stopLvl, freeze) * point;
}


double ClampSL_Donchian_Fusion_D1(const long side, const double proposedSL)
{
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0)
      return 0.0;

   double sl = proposedSL;
   const double minDist = MinStopDistancePrice_Donchian_Fusion_D1();
   if(side == POSITION_TYPE_BUY)
      sl = MathMin(sl, bid - minDist);
   else
      sl = MathMax(sl, ask + minDist);

   return NormalizePrice_Donchian_Fusion_D1(sl);
}


bool ModifySLTPByTicket_Donchian_Fusion_D1(const ulong ticket, const double newSL, const double newTP)
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


bool GetMyPosition_Donchian_Fusion_D1(ulong &ticket, long &type, datetime &openTime, double &sl, double &tp, string &comment)
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


int BarsHeld_Donchian_Fusion_D1(const datetime openTime)
{
   const int shift = iBarShift(_Symbol, InpTimeframe, openTime, false);
   if(shift < 0)
      return 0;
   return shift;
}


int BarsSinceClosed_Donchian_Fusion_D1()
{
   if(g_lastClosedBarTime_Donchian_Fusion_D1 <= 0)
      return InpMinBarsBetweenEntries;

   const int shift = iBarShift(_Symbol, InpTimeframe, g_lastClosedBarTime_Donchian_Fusion_D1, false);
   if(shift < 0)
      return InpMinBarsBetweenEntries;
   return shift;
}


void MarkPositionClosed_Donchian_Fusion_D1()
{
   g_lastClosedBarTime_Donchian_Fusion_D1 = iTime(_Symbol, InpTimeframe, 0);
}


bool EntryCooldownReady_Donchian_Fusion_D1()
{
   if(InpMinBarsBetweenEntries <= 0)
      return true;
   return (BarsSinceClosed_Donchian_Fusion_D1() >= InpMinBarsBetweenEntries);
}


EntryEngine ParseEngineFromComment_Donchian_Fusion_D1(const string comment)
{
   if(StringFind(comment, "|TREND") >= 0)
      return ENGINE_TREND;
   if(StringFind(comment, "|RANGE") >= 0)
      return ENGINE_RANGE;
   return ENGINE_NONE;
}


string BuildCommentByEngine_Donchian_Fusion_D1(const EntryEngine engine)
{
   if(engine == ENGINE_TREND)
      return InpComment + "|TREND";
   if(engine == ENGINE_RANGE)
      return InpComment + "|RANGE";
   return InpComment + "|UNKNOWN";
}


bool IsTrendRegimeConfirmed_Donchian_Fusion_D1()
{
   const int bars = MathMax(1, InpMinRegimeBars);
   for(int shift = 1; shift <= bars; shift++)
   {
      double adxVal = 0.0;
      if(!CopyOne_Donchian_Fusion_D1(g_adxHandle_Donchian_Fusion_D1, 0, shift, adxVal))
         return false;
      if(adxVal < InpADXTrend)
         return false;
   }
   return true;
}


RegimeState DetectRegime_Donchian_Fusion_D1(const double adxPrev, const double bbWidthPrev)
{
   if(IsTrendRegimeConfirmed_Donchian_Fusion_D1())
      return REGIME_TREND;
   if(InpUseRangeEngine && adxPrev <= InpADXRange && bbWidthPrev <= InpRangeBBWMax)
      return REGIME_RANGE;
   return REGIME_NEUTRAL;
}


bool OpenPosition_Donchian_Fusion_D1(const int signal, const double atrPrev, const EntryEngine engine)
{
   if(signal != 1 && signal != -1)
      return false;
   if(atrPrev <= 0.0)
      return false;
   if(!EntryCooldownReady_Donchian_Fusion_D1())
      return false;

   const double lots = NormalizeLots_Donchian_Fusion_D1(InpLots);
   if(lots <= 0.0)
      return false;

   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0)
      return false;

   trade_Donchian_Fusion_D1.SetExpertMagicNumber(InpMagicNumber);
   trade_Donchian_Fusion_D1.SetDeviationInPoints(InpSlippagePoints);

   const string cmt = BuildCommentByEngine_Donchian_Fusion_D1(engine);

   if(signal == 1)
   {
      const double slRaw = ask - (InpSL_ATR * atrPrev);
      const double sl = ClampSL_Donchian_Fusion_D1(POSITION_TYPE_BUY, slRaw);
      return trade_Donchian_Fusion_D1.Buy(lots, _Symbol, 0.0, sl, 0.0, cmt);
   }

   const double slRaw = bid + (InpSL_ATR * atrPrev);
   const double sl = ClampSL_Donchian_Fusion_D1(POSITION_TYPE_SELL, slRaw);
   return trade_Donchian_Fusion_D1.Sell(lots, _Symbol, 0.0, sl, 0.0, cmt);
}


bool ClosePosition_Donchian_Fusion_D1(const ulong ticket)
{
   trade_Donchian_Fusion_D1.SetExpertMagicNumber(InpMagicNumber);
   trade_Donchian_Fusion_D1.SetDeviationInPoints(InpSlippagePoints);
   if(!trade_Donchian_Fusion_D1.PositionClose(ticket))
      return false;

   MarkPositionClosed_Donchian_Fusion_D1();
   return true;
}


void UpdateTrailingStop_Donchian_Fusion_D1(const ulong ticket, const long side, const double currentSL, const double currentTP, const double atrPrev, const double closePrev)
{
   if(atrPrev <= 0.0 || closePrev <= 0.0)
      return;

   if(side == POSITION_TYPE_BUY)
   {
      const double desired = closePrev - (InpTrailATR * atrPrev);
      const double newSL = ClampSL_Donchian_Fusion_D1(POSITION_TYPE_BUY, desired);
      if(newSL > 0.0 && (currentSL == 0.0 || newSL > currentSL + (_Point * 0.5)))
         ModifySLTPByTicket_Donchian_Fusion_D1(ticket, newSL, currentTP);
   }
   else if(side == POSITION_TYPE_SELL)
   {
      const double desired = closePrev + (InpTrailATR * atrPrev);
      const double newSL = ClampSL_Donchian_Fusion_D1(POSITION_TYPE_SELL, desired);
      if(newSL > 0.0 && (currentSL == 0.0 || newSL < currentSL - (_Point * 0.5)))
         ModifySLTPByTicket_Donchian_Fusion_D1(ticket, newSL, currentTP);
   }
}


void BuildFusionSignals_Donchian_Fusion_D1(const double closePrev, const double emaFilter, const double adxPrev,
                                         const double donHighPrev, const double donLowPrev,
                                         bool &trendLong, bool &trendShort)
{
   trendLong = false;
   trendShort = false;

   const bool emaLongOk = (!InpRequireEmaFilter || closePrev > emaFilter);
   const bool emaShortOk = (!InpRequireEmaFilter || closePrev < emaFilter);
   const bool adxOk = (adxPrev >= InpADXEntryMin);

   if(!adxOk)
      return;

   trendLong = (closePrev > donHighPrev && emaLongOk);
   trendShort = (InpAllowShort && closePrev < donLowPrev && emaShortOk);
}


void BuildRegimeTrendSignals_Donchian_Fusion_D1(const RegimeState regime, const double closePrev, const double emaFast,
                                              const double emaSlow, const double donHighPrev, const double donLowPrev,
                                              bool &trendLong, bool &trendShort)
{
   trendLong = false;
   trendShort = false;
   if(regime != REGIME_TREND)
      return;

   if(InpUseDonchianConfirm)
   {
      trendLong = (closePrev > donHighPrev && closePrev > emaSlow);
      trendShort = (InpAllowShort && closePrev < donLowPrev && closePrev < emaSlow);
   }
   else
   {
      trendLong = (emaFast > emaSlow && closePrev > emaSlow);
      trendShort = (InpAllowShort && emaFast < emaSlow && closePrev < emaSlow);
   }
}


void ProcessOnNewDailyBar_Donchian_Fusion_D1()
{
   double emaFast = 0.0, emaFilter = 0.0, adxMain = 0.0, atrPrev = 0.0, rsiPrev = 0.0;
   double bbMid = 0.0, bbUpper = 0.0, bbLower = 0.0;

   if(!CopyOne_Donchian_Fusion_D1(g_emaFilterHandle_Donchian_Fusion_D1, 0, 1, emaFilter))
      return;
   if(!CopyOne_Donchian_Fusion_D1(g_adxHandle_Donchian_Fusion_D1, 0, 1, adxMain))
      return;
   if(!CopyOne_Donchian_Fusion_D1(g_atrHandle_Donchian_Fusion_D1, 0, 1, atrPrev))
      return;

   const bool useRegimePath = (InpEntryMode == ENTRY_REGIME_ADAPT || InpUseRangeEngine);
   if(useRegimePath)
   {
      if(!CopyOne_Donchian_Fusion_D1(g_emaFastHandle_Donchian_Fusion_D1, 0, 1, emaFast))
         return;
      if(!CopyOne_Donchian_Fusion_D1(g_bbHandle_Donchian_Fusion_D1, 0, 1, bbMid))
         return;
      if(!CopyOne_Donchian_Fusion_D1(g_bbHandle_Donchian_Fusion_D1, 1, 1, bbUpper))
         return;
      if(!CopyOne_Donchian_Fusion_D1(g_bbHandle_Donchian_Fusion_D1, 2, 1, bbLower))
         return;
   }

   const double closePrev = iClose(_Symbol, InpTimeframe, 1);
   if(!MathIsValidNumber(closePrev) || closePrev <= 0.0)
      return;
   if(useRegimePath && bbMid <= 0.0)
      return;

   double donHighPrev = 0.0, donLowPrev = 0.0;
   if(InpEntryMode == ENTRY_FUSION_4B || InpUseDonchianConfirm)
   {
      if(!GetDonchianPrev_Donchian_Fusion_D1(InpDonchianPeriod, donHighPrev, donLowPrev))
         return;
   }

   if(InpUseRangeEngine)
   {
      if(!CopyOne_Donchian_Fusion_D1(g_rsiHandle_Donchian_Fusion_D1, 0, 1, rsiPrev))
         return;
   }

   RegimeState regime = REGIME_NEUTRAL;
   if(useRegimePath)
   {
      const double bbWidth = (bbUpper - bbLower) / bbMid;
      regime = DetectRegime_Donchian_Fusion_D1(adxMain, bbWidth);
   }

   bool trendLong = false, trendShort = false;
   bool rangeLong = false, rangeShort = false;

   if(InpEntryMode == ENTRY_FUSION_4B && !InpUseRangeEngine)
      BuildFusionSignals_Donchian_Fusion_D1(closePrev, emaFilter, adxMain, donHighPrev, donLowPrev, trendLong, trendShort);
   else
      BuildRegimeTrendSignals_Donchian_Fusion_D1(regime, closePrev, emaFast, emaFilter, donHighPrev, donLowPrev, trendLong, trendShort);

   if(InpUseRangeEngine && regime == REGIME_RANGE)
   {
      rangeLong = (closePrev < bbLower && rsiPrev <= InpRSILow);
      rangeShort = (InpAllowShort && closePrev > bbUpper && rsiPrev >= InpRSIHigh);
   }

   const bool longSignal = trendLong || rangeLong;
   const bool shortSignal = trendShort || rangeShort;
   const EntryEngine desiredEngine = (trendLong || trendShort ? ENGINE_TREND :
                                      (rangeLong || rangeShort ? ENGINE_RANGE : ENGINE_NONE));

   const bool exitLongRange = ((regime == REGIME_RANGE) && (closePrev >= bbMid)) || (rsiPrev >= InpExitRSILongRange);
   const bool exitShortRange = ((regime == REGIME_RANGE) && (closePrev <= bbMid)) || (rsiPrev <= InpExitRSIShortRange);

   ulong ticket = 0;
   long side = -1;
   datetime openTime = 0;
   double currentSL = 0.0, currentTP = 0.0;
   string posComment = "";
   const bool hasPos = GetMyPosition_Donchian_Fusion_D1(ticket, side, openTime, currentSL, currentTP, posComment);

   if(hasPos)
   {
      const EntryEngine entryEngine = ParseEngineFromComment_Donchian_Fusion_D1(posComment);

      UpdateTrailingStop_Donchian_Fusion_D1(ticket, side, currentSL, currentTP, atrPrev, closePrev);

      const int heldBars = BarsHeld_Donchian_Fusion_D1(openTime);
      if(heldBars >= InpMaxHoldBars)
      {
         ClosePosition_Donchian_Fusion_D1(ticket);
         return;
      }

      if(entryEngine == ENGINE_TREND || entryEngine == ENGINE_NONE)
         return;

      bool shouldExit = false;
      if(side == POSITION_TYPE_BUY)
         shouldExit = exitLongRange;
      else if(side == POSITION_TYPE_SELL)
         shouldExit = exitShortRange;

      if(shouldExit)
         ClosePosition_Donchian_Fusion_D1(ticket);

      return;
   }

   if(desiredEngine != ENGINE_NONE)
   {
      if(longSignal)
         OpenPosition_Donchian_Fusion_D1(1, atrPrev, desiredEngine);
      else if(shortSignal)
         OpenPosition_Donchian_Fusion_D1(-1, atrPrev, desiredEngine);
   }
}


int OnInit()
{
   const int emaTrendLen = (InpEntryMode == ENTRY_FUSION_4B ? InpEmaFilterPeriod : InpEmaSlowPeriod);
   g_emaFilterHandle_Donchian_Fusion_D1 = iMA(_Symbol, InpTimeframe, emaTrendLen, 0, MODE_EMA, PRICE_CLOSE);
   g_adxHandle_Donchian_Fusion_D1         = iADX(_Symbol, InpTimeframe, InpADXPeriod);
   g_atrHandle_Donchian_Fusion_D1         = iATR(_Symbol, InpTimeframe, InpATRPeriod);

   if(InpEntryMode == ENTRY_REGIME_ADAPT || InpUseRangeEngine)
   {
      g_emaFastHandle_Donchian_Fusion_D1 = iMA(_Symbol, InpTimeframe, InpEmaFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
      g_bbHandle_Donchian_Fusion_D1      = iBands(_Symbol, InpTimeframe, InpBBPeriod, 0, InpBBStdDev, PRICE_CLOSE);
   }

   if(InpUseRangeEngine)
      g_rsiHandle_Donchian_Fusion_D1 = iRSI(_Symbol, InpTimeframe, InpRSIPeriod, PRICE_CLOSE);

   if(g_emaFilterHandle_Donchian_Fusion_D1 == INVALID_HANDLE ||
      g_adxHandle_Donchian_Fusion_D1 == INVALID_HANDLE ||
      g_atrHandle_Donchian_Fusion_D1 == INVALID_HANDLE ||
      ((InpEntryMode == ENTRY_REGIME_ADAPT || InpUseRangeEngine) &&
       (g_emaFastHandle_Donchian_Fusion_D1 == INVALID_HANDLE || g_bbHandle_Donchian_Fusion_D1 == INVALID_HANDLE)) ||
      (InpUseRangeEngine && g_rsiHandle_Donchian_Fusion_D1 == INVALID_HANDLE))
   {
      Print("Error al crear handles de indicadores.");
      return INIT_FAILED;
   }

   g_lastBarTime_Donchian_Fusion_D1 = iTime(_Symbol, InpTimeframe, 0);
   trade_Donchian_Fusion_D1.SetExpertMagicNumber(InpMagicNumber);
   trade_Donchian_Fusion_D1.SetDeviationInPoints(InpSlippagePoints);
   Print("Estrategia4d - Donchian_Fusion | BuildTag=", InpBuildTag, " | Mode=", (int)InpEntryMode, " | Magic=", InpMagicNumber);
   return INIT_SUCCEEDED;
}


void OnDeinit(const int reason)
{
   if(g_emaFastHandle_Donchian_Fusion_D1 != INVALID_HANDLE)
      IndicatorRelease(g_emaFastHandle_Donchian_Fusion_D1);
   if(g_emaFilterHandle_Donchian_Fusion_D1 != INVALID_HANDLE)
      IndicatorRelease(g_emaFilterHandle_Donchian_Fusion_D1);
   if(g_adxHandle_Donchian_Fusion_D1 != INVALID_HANDLE)
      IndicatorRelease(g_adxHandle_Donchian_Fusion_D1);
   if(g_atrHandle_Donchian_Fusion_D1 != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle_Donchian_Fusion_D1);
   if(g_rsiHandle_Donchian_Fusion_D1 != INVALID_HANDLE)
      IndicatorRelease(g_rsiHandle_Donchian_Fusion_D1);
   if(g_bbHandle_Donchian_Fusion_D1 != INVALID_HANDLE)
      IndicatorRelease(g_bbHandle_Donchian_Fusion_D1);
}


void OnTick()
{
   if(!IsNewBar_Donchian_Fusion_D1())
      return;

   ProcessOnNewDailyBar_Donchian_Fusion_D1();
}

