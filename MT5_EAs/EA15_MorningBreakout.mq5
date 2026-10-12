//+------------------------------------------------------------------+
//| EA15 - Asian Session Range Morning Breakout                     |
//| Captures the London open breakout of the Asian range            |
//+------------------------------------------------------------------+
#property version "1.00"
#include <Trade\Trade.mqh>
#include "Include/MM_Common.mqh"

input int    AsianStartH  = 0;    input int    AsianEndH    = 7;
input int    LondonOpenH  = 7;    input int    TradeEndH    = 12;
input double ATR_SL_Mult  = 1.0;  input double ATR_TP_Mult  = 2.0;
input int    ATR_Period   = 14;   input double RiskPercent  = 1.0;
input double MaxDailyLoss = 4.0;  input int    MaxTrades    = 1;
input double MinRangePips = 10.0; // Minimum Asian range to trade

CTrade trade;
int    atrH;
double atrBuf[];
double asianHigh = 0, asianLow = 0;
bool   rangeSet  = false;
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

void BuildAsianRange()
{
   asianHigh = -DBL_MAX; asianLow = DBL_MAX;
   datetime dayStart_t = (datetime)(TimeCurrent() - TimeCurrent() % 86400);
   datetime asianStart = dayStart_t + AsianStartH * 3600;
   datetime asianEnd   = dayStart_t + AsianEndH * 3600;

   for(int i = 1; i < 300; i++)
   {
      datetime t = iTime(_Symbol, PERIOD_CURRENT, i);
      if(t < asianStart) break;
      if(t >= asianStart && t < asianEnd)
      {
         asianHigh = MathMax(asianHigh, iHigh(_Symbol, PERIOD_CURRENT, i));
         asianLow  = MathMin(asianLow,  iLow(_Symbol,  PERIOD_CURRENT, i));
      }
   }
   double minRange = MinRangePips * _Point * 10;
   rangeSet = (asianHigh > asianLow && (asianHigh - asianLow) >= minRange);
}

void OnTick()
{
   static datetime lb = 0; datetime cb = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(cb == lb) return; lb = cb;

   int hour = TimeHour(TimeCurrent());
   // Reset range at end of day
   static datetime lastDay = 0;
   datetime today = (datetime)(TimeCurrent() - TimeCurrent() % 86400);
   if(today != lastDay) { lastDay = today; rangeSet = false; dayStart = AccountInfoDouble(ACCOUNT_BALANCE); }

   // Build range just before London open
   if(hour == LondonOpenH - 1 && !rangeSet) BuildAsianRange();
   if(!rangeSet) return;

   if(!MM_DailyLossOK(dayStart, MaxDailyLoss)) return;
   if(hour < LondonOpenH || hour >= TradeEndH) return;
   if(MM_CountTrades(10015) >= MaxTrades) return;

   if(CopyBuffer(atrH, 0, 0, 2, atrBuf) < 2) return;
   double atr   = atrBuf[1];
   double close = iClose(_Symbol, PERIOD_CURRENT, 1);
   double prev  = iClose(_Symbol, PERIOD_CURRENT, 2);
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   bool breakUp   = prev <= asianHigh && close > asianHigh;
   bool breakDown = prev >= asianLow  && close < asianLow;

   if(breakUp)
   { double sl = ask-atr*ATR_SL_Mult; trade.Buy(MM_CalcLots(ask-sl,RiskPercent,10015),_Symbol,ask,sl,ask+atr*ATR_TP_Mult,"EA15 Asian BO Buy"); }
   else if(breakDown)
   { double sl = bid+atr*ATR_SL_Mult; trade.Sell(MM_CalcLots(sl-bid,RiskPercent,10015),_Symbol,bid,sl,bid-atr*ATR_TP_Mult,"EA15 Asian BO Sell"); }
}
void OnDeinit(const int reason) {}
