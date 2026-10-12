//+------------------------------------------------------------------+
//| EA15 - Asian Session Range Morning Breakout                     |
//| Captures the London open breakout of the Asian range            |
//+------------------------------------------------------------------+
#property version "1.00"
#include <Trade\Trade.mqh>
#include "Include/Portfolio.mqh"

input int    AsianStartH  = 0;    input int    AsianEndH    = 7;
input int    LondonOpenH  = 7;    input int    TradeEndH    = 12;
input double ATR_SL_Mult  = 1.0;  input double ATR_TP_Mult  = 2.0;
input int    ATR_Period   = 14;   input double RiskPercent  = 1.0;
input double MaxDailyLoss = 4.0;  input int    MaxTrades    = 1;
input double MinRangePips = 10.0; // Minimum Asian range to trade
input int    ServerGMTOffset = 0;   // Broker server hours ahead of GMT; 0 = legacy (session hours are server hours)
input bool   OneTradePerDay  = false; // true = at most one breakout trade per day, even after a stop-out (false = legacy)

CTrade trade;
int    atrH;
double atrBuf[];
double asianHigh = 0, asianLow = 0;
bool   rangeBuilt  = false; // range attempted today
bool   rangeSet    = false; // range valid today
bool   tradedToday = false;
double dayStart  = 0;

int OnInit()
{
   atrH = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);
   if(atrH == INVALID_HANDLE) return INIT_FAILED;
   ArraySetAsSeries(atrBuf, true);
   trade.SetExpertMagicNumber(10015);
   dayStart = AccountInfoDouble(ACCOUNT_BALANCE);
   return INIT_SUCCEEDED;
}

// Session clock: server time shifted to GMT. With ServerGMTOffset = 0 this is the broker clock.
datetime ToGMT(datetime serverTime) { return serverTime - ServerGMTOffset * 3600; }

// One pip: 3- and 5-digit quotes use 10 points per pip, 2- and 4-digit quotes use 1 point
double PipSize() { return (_Digits == 3 || _Digits == 5) ? _Point * 10 : _Point; }

void BuildAsianRange()
{
   asianHigh = -DBL_MAX; asianLow = DBL_MAX;
   datetime gmtNow     = ToGMT(TimeCurrent());
   datetime dayStart_t = gmtNow - gmtNow % 86400;
   datetime asianStart = dayStart_t + AsianStartH * 3600;
   datetime asianEnd   = dayStart_t + AsianEndH * 3600;

   // Scan back until the Asian window starts. Bar 0 (still forming) is excluded.
   // No fixed bar cap: on M1 the window alone is 420 bars.
   for(int i = 1; i < Bars(_Symbol, PERIOD_CURRENT); i++)
   {
      datetime t = ToGMT(iTime(_Symbol, PERIOD_CURRENT, i));
      if(t < asianStart) break;
      if(t < asianEnd)
      {
         asianHigh = MathMax(asianHigh, iHigh(_Symbol, PERIOD_CURRENT, i));
         asianLow  = MathMin(asianLow,  iLow(_Symbol,  PERIOD_CURRENT, i));
      }
   }
   double minRange = MinRangePips * PipSize();
   rangeSet = (asianHigh > asianLow && (asianHigh - asianLow) >= minRange);
}

void OnTick()
{
   PF_Update();
   static datetime lb = 0; datetime cb = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(cb == lb) return; lb = cb;

   datetime gmt  = ToGMT(TimeCurrent());
   int      hour = MM_Hour(gmt);
   // Reset the day's state at each session day boundary
   static datetime lastDay = 0;
   datetime today = gmt - gmt % 86400;
   if(today != lastDay)
   {
      lastDay = today;
      rangeBuilt = false; rangeSet = false; tradedToday = false;
      dayStart = AccountInfoDouble(ACCOUNT_BALANCE);
   }

   // Build the range once, when the Asian window closes (AsianEndH).
   // Before this change the build ran at LondonOpenH-1, so AsianEndH never took effect.
   if(hour == AsianEndH && !rangeBuilt)
   {
      BuildAsianRange();
      rangeBuilt = true;
   }
   if(!rangeSet) return;

   if(!MM_DailyLossOK(dayStart, MaxDailyLoss)) return;
   if(hour < LondonOpenH || hour >= TradeEndH) return;
   if(MM_CountTrades(10015) >= MaxTrades) return;
   if(OneTradePerDay && tradedToday) return;

   if(CopyBuffer(atrH, 0, 0, 2, atrBuf) < 2) return;
   double atr   = atrBuf[1];
   double close = iClose(_Symbol, PERIOD_CURRENT, 1);
   double prev  = iClose(_Symbol, PERIOD_CURRENT, 2);
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   bool breakUp   = prev <= asianHigh && close > asianHigh;
   bool breakDown = prev >= asianLow  && close < asianLow;

   if(breakUp)
   {
      double sl   = ask - atr * ATR_SL_Mult;
      double lots = PF_Lots(ORDER_TYPE_BUY, ask, sl, RiskPercent, 10015);
      if(lots > 0 && trade.Buy(lots, _Symbol, ask, sl, ask + atr * ATR_TP_Mult, "EA15 Asian BO Buy")) tradedToday = true;
   }
   else if(breakDown)
   {
      double sl   = bid + atr * ATR_SL_Mult;
      double lots = PF_Lots(ORDER_TYPE_SELL, bid, sl, RiskPercent, 10015);
      if(lots > 0 && trade.Sell(lots, _Symbol, bid, sl, bid - atr * ATR_TP_Mult, "EA15 Asian BO Sell")) tradedToday = true;
   }
}
void OnDeinit(const int reason) {}
