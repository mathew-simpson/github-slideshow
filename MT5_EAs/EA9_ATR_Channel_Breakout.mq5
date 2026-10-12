//+------------------------------------------------------------------+
//|  EA9 - ATR Channel Breakout (Donchian-style)                     |
//|  Strategy: Break of N-bar high/low with ATR expansion confirm    |
//|  Filter: Volume rising, ATR expanding                            |
//+------------------------------------------------------------------+
#property copyright "MT5 Trading System"
#property version   "1.00"

#include <Trade\Trade.mqh>
#include "Include/Portfolio.mqh"

input group "=== Breakout Settings ==="
input int    Channel_Period = 20;     // Bars to look back for high/low
input int    ATR_Period     = 14;
input double ATR_Expand_Min = 1.1;    // ATR must be this multiple of avg
input int    ATR_Avg_Period = 50;     // Bars to average ATR for comparison
input double ATR_SL_Mult    = 1.5;
input double ATR_TP_Mult    = 3.0;

input group "=== Risk Management ==="
input double RiskPercent    = 0.75;
input double MaxDailyLoss   = 4.0;
input int    MaxTrades      = 2;

input group "=== Session Filter ==="
input int    StartHour      = 7;
input int    EndHour        = 20;

CTrade trade;
int    atrHandle;
double atrBuf[];
double dayStartBalance = 0;

int OnInit()
{
   atrHandle = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);
   if(atrHandle == INVALID_HANDLE) { Print("ATR init failed"); return INIT_FAILED; }
   ArraySetAsSeries(atrBuf, true);
   trade.SetExpertMagicNumber(10009);
   dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   return INIT_SUCCEEDED;
}

bool IsTradingSession()
{
   int hour = MM_Hour(TimeCurrent());
   return (hour >= StartHour && hour < EndHour);
}

bool DailyLossExceeded()
{
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double drawdown = (dayStartBalance - balance) / dayStartBalance * 100.0;
   return (drawdown >= MaxDailyLoss);
}

int CountOpenTrades()
{
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == 10009)
         count++;
   return count;
}

bool IsATRExpanding()
{
   if(CopyBuffer(atrHandle, 0, 0, ATR_Avg_Period + 2, atrBuf) < ATR_Avg_Period + 2)
      return false;

   double currentATR = atrBuf[1];
   double avgATR     = 0;
   for(int i = 2; i < ATR_Avg_Period + 2; i++)
      avgATR += atrBuf[i];
   avgATR /= ATR_Avg_Period;

   return currentATR >= avgATR * ATR_Expand_Min;
}

void OnTick()
{
   PF_Update();
   static datetime lastBar = 0;
   datetime curBar = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(curBar == lastBar) return;
   lastBar = curBar;

   static datetime lastDay = 0;
   datetime today = (datetime)(TimeCurrent() - TimeCurrent() % 86400);
   if(today != lastDay) { lastDay = today; dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE); }

   if(!IsTradingSession())           return;
   if(DailyLossExceeded())           return;
   if(CountOpenTrades() >= MaxTrades) return;
   if(!IsATRExpanding())             return;

   if(CopyBuffer(atrHandle, 0, 0, 2, atrBuf) < 2) return;
   double atr = atrBuf[1];

   // Channel high and low over the Channel_Period bars before the signal bar (bars 2..N+1).
   // Bar 1 is the signal bar and must not be part of its own channel.
   double nBarHigh = iHigh(_Symbol, PERIOD_CURRENT, 2);
   double nBarLow  = iLow(_Symbol, PERIOD_CURRENT, 2);
   for(int i = 3; i <= Channel_Period + 1; i++)
   {
      nBarHigh = MathMax(nBarHigh, iHigh(_Symbol, PERIOD_CURRENT, i));
      nBarLow  = MathMin(nBarLow,  iLow(_Symbol, PERIOD_CURRENT, i));
   }

   double close1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   double close2 = iClose(_Symbol, PERIOD_CURRENT, 2);
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   bool breakoutUp   = close1 > nBarHigh && close2 <= nBarHigh;
   bool breakoutDown = close1 < nBarLow  && close2 >= nBarLow;

   if(breakoutUp)
   {
      double sl   = ask - atr * ATR_SL_Mult;
      double tp   = ask + atr * ATR_TP_Mult;
      double lots = PF_Lots(ORDER_TYPE_BUY, ask, sl, RiskPercent, 10009);
      if(lots > 0) trade.Buy(lots, _Symbol, ask, sl, tp, "EA9 Channel Breakout Buy");
   }
   else if(breakoutDown)
   {
      double sl   = bid + atr * ATR_SL_Mult;
      double tp   = bid - atr * ATR_TP_Mult;
      double lots = PF_Lots(ORDER_TYPE_SELL, bid, sl, RiskPercent, 10009);
      if(lots > 0) trade.Sell(lots, _Symbol, bid, sl, tp, "EA9 Channel Breakout Sell");
   }
}

void OnDeinit(const int reason) {}
