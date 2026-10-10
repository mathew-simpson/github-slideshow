//+------------------------------------------------------------------+
//|  EA2 - RSI Mean Reversion                                        |
//|  Strategy: Buy oversold RSI, Sell overbought RSI                 |
//|  Filter: Only trade with trend (200 EMA direction)               |
//+------------------------------------------------------------------+
#property copyright "MT5 Trading System"
#property version   "1.00"

#include <Trade\Trade.mqh>

input group "=== Strategy Settings ==="
input int    RSI_Period    = 14;
input double OversoldLevel = 30.0;
input double OverboughtLvl = 70.0;
input int    EMA_Trend     = 200;
input int    ATR_Period    = 14;
input double ATR_SL_Mult   = 1.5;
input double ATR_TP_Mult   = 2.0;

input group "=== Risk Management ==="
input double RiskPercent   = 1.0;
input double MaxDailyLoss  = 5.0;
input int    MaxTrades     = 2;

input group "=== Session Filter ==="
input int    StartHour     = 7;
input int    EndHour       = 20;

CTrade trade;
int    rsiHandle, emaHandle, atrHandle;
double rsiBuf[], emaBuf[], atrBuf[];
double dayStartBalance = 0;

int OnInit()
{
   rsiHandle = iRSI(_Symbol, PERIOD_CURRENT, RSI_Period, PRICE_CLOSE);
   emaHandle = iMA(_Symbol, PERIOD_CURRENT, EMA_Trend, 0, MODE_EMA, PRICE_CLOSE);
   atrHandle = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);

   if(rsiHandle == INVALID_HANDLE || emaHandle == INVALID_HANDLE || atrHandle == INVALID_HANDLE)
   { Print("Indicator init failed"); return INIT_FAILED; }

   ArraySetAsSeries(rsiBuf, true);
   ArraySetAsSeries(emaBuf, true);
   ArraySetAsSeries(atrBuf, true);

   trade.SetExpertMagicNumber(10002);
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
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == 10002)
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

void OnTick()
{
   static datetime lastBar = 0;
   datetime curBar = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(curBar == lastBar) return;
   lastBar = curBar;

   // Daily reset
   static datetime lastDay = 0;
   datetime today = (datetime)(TimeCurrent() - TimeCurrent() % 86400);
   if(today != lastDay) { lastDay = today; dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE); }

   if(!IsTradingSession())           return;
   if(DailyLossExceeded())           return;
   if(CountOpenTrades() >= MaxTrades) return;

   if(CopyBuffer(rsiHandle, 0, 0, 3, rsiBuf) < 3) return;
   if(CopyBuffer(emaHandle, 0, 0, 2, emaBuf) < 2) return;
   if(CopyBuffer(atrHandle, 0, 0, 2, atrBuf) < 2) return;

   double rsiCur  = rsiBuf[1];
   double rsiPrev = rsiBuf[2];
   double ema     = emaBuf[1];
   double atr     = atrBuf[1];
   double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double close   = iClose(_Symbol, PERIOD_CURRENT, 1);

   bool aboveTrend = close > ema;
   bool belowTrend = close < ema;

   // RSI crosses back above oversold - buy signal (with uptrend)
   bool buySignal  = (rsiPrev < OversoldLevel && rsiCur >= OversoldLevel) && aboveTrend;
   // RSI crosses back below overbought - sell signal (with downtrend)
   bool sellSignal = (rsiPrev > OverboughtLvl && rsiCur <= OverboughtLvl) && belowTrend;

   if(buySignal)
   {
      double sl   = ask - atr * ATR_SL_Mult;
      double tp   = ask + atr * ATR_TP_Mult;
      double lots = CalcLotSize(atr * ATR_SL_Mult);
      trade.Buy(lots, _Symbol, ask, sl, tp, "EA2 Buy");
   }
   else if(sellSignal)
   {
      double sl   = bid + atr * ATR_SL_Mult;
      double tp   = bid - atr * ATR_TP_Mult;
      double lots = CalcLotSize(atr * ATR_SL_Mult);
      trade.Sell(lots, _Symbol, bid, sl, tp, "EA2 Sell");
   }
}

void OnDeinit(const int reason) {}
