//+------------------------------------------------------------------+
//|  EA1 - MA Crossover with ATR Stop/TP                             |
//|  Strategy: Fast EMA crosses above/below Slow EMA                 |
//|  Risk: % of account balance per trade                            |
//+------------------------------------------------------------------+
#property copyright "MT5 Trading System"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include "Include/Portfolio.mqh"

input group "=== Strategy Settings ==="
input int    FastMA_Period  = 20;
input int    SlowMA_Period  = 50;
input int    ATR_Period     = 14;
input double ATR_SL_Mult   = 1.5;
input double ATR_TP_Mult   = 3.0;

input group "=== Risk Management ==="
input double RiskPercent   = 1.0;    // Risk % per trade
input double MaxDailyLoss  = 5.0;    // Max daily loss %
input int    MaxTrades     = 3;      // Max simultaneous trades
input bool   UseTrailing   = true;
input double TrailATRMult  = 1.0;

input group "=== Session Filter ==="
input int    StartHour     = 7;
input int    EndHour       = 20;

CTrade trade;
int    fastHandle, slowHandle, atrHandle;
double fastMA[], slowMA[], atrBuf[];
double dayStartBalance = 0;

int OnInit()
{
   fastHandle = iMA(_Symbol, PERIOD_CURRENT, FastMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   slowHandle = iMA(_Symbol, PERIOD_CURRENT, SlowMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   atrHandle  = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);

   if(fastHandle == INVALID_HANDLE || slowHandle == INVALID_HANDLE || atrHandle == INVALID_HANDLE)
   {
      Print("Error creating indicators");
      return INIT_FAILED;
   }

   ArraySetAsSeries(fastMA, true);
   ArraySetAsSeries(slowMA, true);
   ArraySetAsSeries(atrBuf, true);

   trade.SetExpertMagicNumber(10001);
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
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double drawdown = (dayStartBalance - balance) / dayStartBalance * 100.0;
   return (drawdown >= MaxDailyLoss);
}

int CountOpenTrades()
{
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == 10001)
         count++;
   return count;
}

void ManageTrailing()
{
   if(!UseTrailing) return;

   if(CopyBuffer(atrHandle, 0, 0, 2, atrBuf) < 2) return;
   double atr = atrBuf[0];

   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(PositionGetSymbol(i) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != 10001) continue;

      long   type    = PositionGetInteger(POSITION_TYPE);
      double openPr  = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL   = PositionGetDouble(POSITION_SL);
      double curTP   = PositionGetDouble(POSITION_TP);
      ulong  ticket  = PositionGetInteger(POSITION_TICKET);

      if(type == POSITION_TYPE_BUY)
      {
         double newSL = SymbolInfoDouble(_Symbol, SYMBOL_BID) - atr * TrailATRMult;
         if(newSL > curSL + _Point)
            trade.PositionModify(ticket, newSL, curTP);
      }
      else if(type == POSITION_TYPE_SELL)
      {
         double newSL = SymbolInfoDouble(_Symbol, SYMBOL_ASK) + atr * TrailATRMult;
         if(newSL < curSL - _Point || curSL == 0)
            trade.PositionModify(ticket, newSL, curTP);
      }
   }
}

void OnTick()
{
   PF_Update();
   // Reset day balance at start of new day
   static datetime lastDay = 0;
   datetime today = (datetime)(TimeCurrent() - TimeCurrent() % 86400);
   if(today != lastDay)
   {
      lastDay = today;
      dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   }

   ManageTrailing();

   if(!IsTradingSession())      return;
   if(DailyLossExceeded())      return;
   if(CountOpenTrades() >= MaxTrades) return;

   if(CopyBuffer(fastHandle, 0, 0, 3, fastMA) < 3) return;
   if(CopyBuffer(slowHandle, 0, 0, 3, slowMA) < 3) return;
   if(CopyBuffer(atrHandle,  0, 0, 2, atrBuf) < 2) return;

   bool crossUp   = fastMA[1] > slowMA[1] && fastMA[2] <= slowMA[2];
   bool crossDown = fastMA[1] < slowMA[1] && fastMA[2] >= slowMA[2];

   double atr   = atrBuf[0];
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(crossUp)
   {
      double sl   = ask - atr * ATR_SL_Mult;
      double tp   = ask + atr * ATR_TP_Mult;
      double lots = PF_Lots(ORDER_TYPE_BUY, ask, sl, RiskPercent, 10001);
      if(lots > 0) trade.Buy(lots, _Symbol, ask, sl, tp, "EA1 Buy");
   }
   else if(crossDown)
   {
      double sl   = bid + atr * ATR_SL_Mult;
      double tp   = bid - atr * ATR_TP_Mult;
      double lots = PF_Lots(ORDER_TYPE_SELL, bid, sl, RiskPercent, 10001);
      if(lots > 0) trade.Sell(lots, _Symbol, bid, sl, tp, "EA1 Sell");
   }
}

void OnDeinit(const int reason) {}
