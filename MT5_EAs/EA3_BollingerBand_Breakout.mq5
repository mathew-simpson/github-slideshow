//+------------------------------------------------------------------+
//|  EA3 - Bollinger Band Breakout                                   |
//|  Strategy: Trade breakouts beyond bands after squeeze            |
//|  Filter: BB width squeeze then expansion                         |
//+------------------------------------------------------------------+
#property copyright "MT5 Trading System"
#property version   "1.00"

#include <Trade\Trade.mqh>

input group "=== Strategy Settings ==="
input int    BB_Period      = 20;
input double BB_Deviation   = 2.0;
input int    ATR_Period     = 14;
input double ATR_SL_Mult    = 1.5;
input double ATR_TP_Mult    = 2.5;
input int    SquezeBars     = 5;       // Bars to look back for squeeze
input double SquezeThresh   = 0.002;   // Min width % for breakout

input group "=== Risk Management ==="
input double RiskPercent    = 1.0;
input double MaxDailyLoss   = 5.0;
input int    MaxTrades      = 2;

input group "=== Session Filter ==="
input int    StartHour      = 7;
input int    EndHour        = 20;

CTrade trade;
int    bbHandle, atrHandle;
double bbUpper[], bbLower[], bbMiddle[], atrBuf[];
double dayStartBalance = 0;

int OnInit()
{
   bbHandle  = iBands(_Symbol, PERIOD_CURRENT, BB_Period, 0, BB_Deviation, PRICE_CLOSE);
   atrHandle = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);

   if(bbHandle == INVALID_HANDLE || atrHandle == INVALID_HANDLE)
   { Print("Indicator init failed"); return INIT_FAILED; }

   ArraySetAsSeries(bbUpper,  true);
   ArraySetAsSeries(bbLower,  true);
   ArraySetAsSeries(bbMiddle, true);
   ArraySetAsSeries(atrBuf,   true);

   trade.SetExpertMagicNumber(10003);
   dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   return INIT_SUCCEEDED;
}

bool IsTradingSession()
{
   int hour = TimeHour(TimeCurrent());
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
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == 10003)
         count++;
   return count;
}

double CalcLotSize(double slPoints)
{
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmt  = balance * RiskPercent / 100.0;
   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double lotStep  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   double lots = riskAmt / (slPoints / tickSize * tickVal);
   lots = MathFloor(lots / lotStep) * lotStep;
   return MathMax(minLot, MathMin(maxLot, lots));
}

bool IsSqueeze()
{
   // Check that prior bars had narrow bands (squeeze condition)
   if(CopyBuffer(bbHandle, 1, 1, SquezeBars + 1, bbUpper) < SquezeBars + 1) return false;
   if(CopyBuffer(bbHandle, 2, 1, SquezeBars + 1, bbLower) < SquezeBars + 1) return false;
   if(CopyBuffer(bbHandle, 0, 1, SquezeBars + 1, bbMiddle) < SquezeBars + 1) return false;

   for(int i = 1; i <= SquezeBars; i++)
   {
      double width = (bbUpper[i] - bbLower[i]) / bbMiddle[i];
      if(width > SquezeThresh) return false;
   }
   return true;
}

void OnTick()
{
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

   if(CopyBuffer(bbHandle, 1, 0, 3, bbUpper)  < 3) return;
   if(CopyBuffer(bbHandle, 2, 0, 3, bbLower)  < 3) return;
   if(CopyBuffer(bbHandle, 0, 0, 3, bbMiddle) < 3) return;
   if(CopyBuffer(atrHandle, 0, 0, 2, atrBuf)  < 2) return;

   double close1  = iClose(_Symbol, PERIOD_CURRENT, 1);
   double close2  = iClose(_Symbol, PERIOD_CURRENT, 2);
   double atr     = atrBuf[1];
   double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // Breakout: price closes outside band after squeeze
   bool buyBreak  = (close1 > bbUpper[1] && close2 <= bbUpper[2]);
   bool sellBreak = (close1 < bbLower[1] && close2 >= bbLower[2]);

   if(buyBreak)
   {
      double sl   = ask - atr * ATR_SL_Mult;
      double tp   = ask + atr * ATR_TP_Mult;
      double lots = CalcLotSize(atr * ATR_SL_Mult);
      trade.Buy(lots, _Symbol, ask, sl, tp, "EA3 Buy Breakout");
   }
   else if(sellBreak)
   {
      double sl   = bid + atr * ATR_SL_Mult;
      double tp   = bid - atr * ATR_TP_Mult;
      double lots = CalcLotSize(atr * ATR_SL_Mult);
      trade.Sell(lots, _Symbol, bid, sl, tp, "EA3 Sell Breakout");
   }
}

void OnDeinit(const int reason) {}
