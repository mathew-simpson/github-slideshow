//+------------------------------------------------------------------+
//|  EA12 - Scalping Momentum (M1/M5)                                |
//|  Strategy: Fast RSI + EMA ribbon for short-term momentum scalps  |
//|  Best on: M1, M5 timeframes during high liquidity sessions       |
//+------------------------------------------------------------------+
#property copyright "MT5 Trading System"
#property version   "1.00"

#include <Trade\Trade.mqh>
#include "Include/Portfolio.mqh"

input group "=== Scalp Settings ==="
input int    FastEMA       = 5;
input int    SlowEMA       = 13;
input int    RSI_Period    = 7;
input double RSI_BuyThresh = 55.0;   // RSI must be above for buy
input double RSI_SellThresh = 45.0;  // RSI must be below for sell
input int    ATR_Period    = 10;
input double ATR_SL_Mult   = 1.0;
input double ATR_TP_Mult   = 1.5;
input int    MaxBarsHeld   = 20;     // Force close if held too long

input group "=== Risk Management ==="
input double RiskPercent   = 0.5;    // Smaller risk for scalping
input double MaxDailyLoss  = 3.0;
input int    MaxTrades     = 3;

input group "=== Session Filter ==="
input int    LondonOpen    = 8;
input int    LondonClose   = 12;
input int    NYOpen        = 13;
input int    NYClose       = 17;

CTrade trade;
int    fastHandle, slowHandle, rsiHandle, atrHandle;
double fastBuf[], slowBuf[], rsiBuf[], atrBuf[];
double dayStartBalance = 0;
datetime tradeOpenTimes[];

int OnInit()
{
   fastHandle = iMA(_Symbol, PERIOD_CURRENT, FastEMA, 0, MODE_EMA, PRICE_CLOSE);
   slowHandle = iMA(_Symbol, PERIOD_CURRENT, SlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   rsiHandle  = iRSI(_Symbol, PERIOD_CURRENT, RSI_Period, PRICE_CLOSE);
   atrHandle  = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);

   if(fastHandle == INVALID_HANDLE || slowHandle == INVALID_HANDLE ||
      rsiHandle == INVALID_HANDLE || atrHandle == INVALID_HANDLE)
   { Print("Indicator init failed"); return INIT_FAILED; }

   ArraySetAsSeries(fastBuf, true);
   ArraySetAsSeries(slowBuf, true);
   ArraySetAsSeries(rsiBuf,  true);
   ArraySetAsSeries(atrBuf,  true);

   trade.SetExpertMagicNumber(10012);
   dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   return INIT_SUCCEEDED;
}

bool IsScalpSession()
{
   int hour = MM_Hour(TimeCurrent());
   return (hour >= LondonOpen && hour < LondonClose) ||
          (hour >= NYOpen && hour < NYClose);
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
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == 10012)
         count++;
   return count;
}

void ForceCloseOldTrades()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != 10012) continue;

      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      datetime curTime  = TimeCurrent();
      int      barsHeld = Bars(_Symbol, PERIOD_CURRENT, openTime, curTime);

      if(barsHeld >= MaxBarsHeld)
         trade.PositionClose(PositionGetInteger(POSITION_TICKET));
   }
}

void OnTick()
{
   PF_Update();
   ForceCloseOldTrades();

   static datetime lastDay = 0;
   datetime today = (datetime)(TimeCurrent() - TimeCurrent() % 86400);
   if(today != lastDay) { lastDay = today; dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE); }

   if(!IsScalpSession())             return;
   if(DailyLossExceeded())           return;
   if(CountOpenTrades() >= MaxTrades) return;

   if(CopyBuffer(fastHandle, 0, 0, 3, fastBuf) < 3) return;
   if(CopyBuffer(slowHandle, 0, 0, 3, slowBuf) < 3) return;
   if(CopyBuffer(rsiHandle,  0, 0, 2, rsiBuf)  < 2) return;
   if(CopyBuffer(atrHandle,  0, 0, 2, atrBuf)  < 2) return;

   double fast1 = fastBuf[1], fast2 = fastBuf[2];
   double slow1 = slowBuf[1], slow2 = slowBuf[2];
   double rsi   = rsiBuf[1];
   double atr   = atrBuf[1];
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   bool emaCrossUp   = fast2 <= slow2 && fast1 > slow1;
   bool emaCrossDown = fast2 >= slow2 && fast1 < slow1;

   if(emaCrossUp && rsi > RSI_BuyThresh)
   {
      double sl   = ask - atr * ATR_SL_Mult;
      double tp   = ask + atr * ATR_TP_Mult;
      double lots = PF_Lots(ORDER_TYPE_BUY, ask, sl, RiskPercent, 10012);
      if(lots > 0) trade.Buy(lots, _Symbol, ask, sl, tp, "EA12 Scalp Buy");
   }
   else if(emaCrossDown && rsi < RSI_SellThresh)
   {
      double sl   = bid + atr * ATR_SL_Mult;
      double tp   = bid - atr * ATR_TP_Mult;
      double lots = PF_Lots(ORDER_TYPE_SELL, bid, sl, RiskPercent, 10012);
      if(lots > 0) trade.Sell(lots, _Symbol, bid, sl, tp, "EA12 Scalp Sell");
   }
}

void OnDeinit(const int reason) {}
