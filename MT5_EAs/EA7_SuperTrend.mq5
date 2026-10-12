//+------------------------------------------------------------------+
//|  EA7 - SuperTrend Following                                      |
//|  Strategy: Trade in direction of SuperTrend indicator            |
//|  Entry: SuperTrend flip confirmed by close                       |
//+------------------------------------------------------------------+
#property copyright "MT5 Trading System"
#property version   "1.00"

#include <Trade\Trade.mqh>
#include "Include/Portfolio.mqh"

input group "=== SuperTrend Settings ==="
input int    ATR_Period     = 10;
input double ATR_Multiplier = 3.0;
input double ATR_SL_Mult    = 1.0;   // ATR mult for SL beyond SuperTrend
input double ATR_TP_Mult    = 4.0;

input group "=== Risk Management ==="
input double RiskPercent    = 1.0;
input double MaxDailyLoss   = 5.0;
input int    MaxTrades      = 1;
input bool   UseTrailing    = true;

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
   trade.SetExpertMagicNumber(10007);
   dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   return INIT_SUCCEEDED;
}

// Compute SuperTrend manually
void CalcSuperTrend(int bar, double &stValue, int &stDir)
{
   if(CopyBuffer(atrHandle, 0, bar, 1, atrBuf) < 1) { stValue = 0; stDir = 0; return; }
   double atr  = atrBuf[0];
   double high = iHigh(_Symbol, PERIOD_CURRENT, bar);
   double low  = iLow(_Symbol, PERIOD_CURRENT, bar);
   double hl2  = (high + low) / 2.0;

   double upperBand = hl2 + ATR_Multiplier * atr;
   double lowerBand = hl2 - ATR_Multiplier * atr;
   double close     = iClose(_Symbol, PERIOD_CURRENT, bar);

   // Simple approximation - in production use a proper buffer
   stValue = (close > hl2) ? lowerBand : upperBand;
   stDir   = (close > stValue) ? 1 : -1;
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
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == 10007)
         count++;
   return count;
}

void ManageTrailing()
{
   if(!UseTrailing) return;
   if(CopyBuffer(atrHandle, 0, 0, 2, atrBuf) < 2) return;
   double atr = atrBuf[1];

   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(PositionGetSymbol(i) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != 10007) continue;

      ulong  ticket = PositionGetInteger(POSITION_TICKET);
      long   type   = PositionGetInteger(POSITION_TYPE);
      double curSL  = PositionGetDouble(POSITION_SL);
      double curTP  = PositionGetDouble(POSITION_TP);

      double stVal; int stDir;
      CalcSuperTrend(1, stVal, stDir);

      if(type == POSITION_TYPE_BUY)
      {
         double newSL = stVal - atr * ATR_SL_Mult;
         if(newSL > curSL + _Point)
            trade.PositionModify(ticket, newSL, curTP);
      }
      else
      {
         double newSL = stVal + atr * ATR_SL_Mult;
         if(curSL == 0 || newSL < curSL - _Point)
            trade.PositionModify(ticket, newSL, curTP);
      }
   }
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

   ManageTrailing();

   if(!IsTradingSession())           return;
   if(DailyLossExceeded())           return;
   if(CountOpenTrades() >= MaxTrades) return;

   double stVal1, stVal2; int stDir1, stDir2;
   CalcSuperTrend(1, stVal1, stDir1);
   CalcSuperTrend(2, stVal2, stDir2);

   if(CopyBuffer(atrHandle, 0, 0, 2, atrBuf) < 2) return;
   double atr = atrBuf[1];
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   bool flipUp   = stDir2 == -1 && stDir1 == 1;
   bool flipDown = stDir2 ==  1 && stDir1 == -1;

   if(flipUp)
   {
      double sl   = stVal1 - atr * ATR_SL_Mult;
      double tp   = ask + atr * ATR_TP_Mult;
      double lots = PF_Lots(ORDER_TYPE_BUY, ask, sl, RiskPercent, 10007);
      if(lots > 0) trade.Buy(lots, _Symbol, ask, sl, tp, "EA7 SuperTrend Buy");
   }
   else if(flipDown)
   {
      double sl   = stVal1 + atr * ATR_SL_Mult;
      double tp   = bid - atr * ATR_TP_Mult;
      double lots = PF_Lots(ORDER_TYPE_SELL, bid, sl, RiskPercent, 10007);
      if(lots > 0) trade.Sell(lots, _Symbol, bid, sl, tp, "EA7 SuperTrend Sell");
   }
}

void OnDeinit(const int reason) {}
