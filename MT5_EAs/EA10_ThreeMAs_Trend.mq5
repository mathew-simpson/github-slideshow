//+------------------------------------------------------------------+
//|  EA10 - Three Moving Average Trend System                        |
//|  Strategy: Fast/Mid/Slow MA aligned + price pullback entry       |
//|  Entry: All 3 MAs aligned, price pulls back to mid MA           |
//+------------------------------------------------------------------+
#property copyright "MT5 Trading System"
#property version   "1.00"

#include <Trade\Trade.mqh>

input group "=== MA Settings ==="
input int    FastMA        = 10;
input int    MidMA         = 21;
input int    SlowMA        = 50;
input ENUM_MA_METHOD MAType = MODE_EMA;
input int    ATR_Period    = 14;
input double ATR_SL_Mult   = 1.5;
input double ATR_TP_Mult   = 2.5;
input double PullbackZone  = 0.5;   // How close price must be to mid MA (as ATR fraction)

input group "=== Risk Management ==="
input double RiskPercent   = 1.0;
input double MaxDailyLoss  = 5.0;
input int    MaxTrades     = 2;

input group "=== Session Filter ==="
input int    StartHour     = 7;
input int    EndHour       = 20;

CTrade trade;
int    fastHandle, midHandle, slowHandle, atrHandle;
double fastBuf[], midBuf[], slowBuf[], atrBuf[];
double dayStartBalance = 0;

int OnInit()
{
   fastHandle = iMA(_Symbol, PERIOD_CURRENT, FastMA, 0, MAType, PRICE_CLOSE);
   midHandle  = iMA(_Symbol, PERIOD_CURRENT, MidMA,  0, MAType, PRICE_CLOSE);
   slowHandle = iMA(_Symbol, PERIOD_CURRENT, SlowMA, 0, MAType, PRICE_CLOSE);
   atrHandle  = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);

   if(fastHandle == INVALID_HANDLE || midHandle == INVALID_HANDLE ||
      slowHandle == INVALID_HANDLE || atrHandle == INVALID_HANDLE)
   { Print("Indicator init failed"); return INIT_FAILED; }

   ArraySetAsSeries(fastBuf, true);
   ArraySetAsSeries(midBuf,  true);
   ArraySetAsSeries(slowBuf, true);
   ArraySetAsSeries(atrBuf,  true);

   trade.SetExpertMagicNumber(10010);
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
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == 10010)
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

   static datetime lastDay = 0;
   datetime today = (datetime)(TimeCurrent() - TimeCurrent() % 86400);
   if(today != lastDay) { lastDay = today; dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE); }

   if(!IsTradingSession())           return;
   if(DailyLossExceeded())           return;
   if(CountOpenTrades() >= MaxTrades) return;

   if(CopyBuffer(fastHandle, 0, 0, 2, fastBuf) < 2) return;
   if(CopyBuffer(midHandle,  0, 0, 2, midBuf)  < 2) return;
   if(CopyBuffer(slowHandle, 0, 0, 2, slowBuf) < 2) return;
   if(CopyBuffer(atrHandle,  0, 0, 2, atrBuf)  < 2) return;

   double fast  = fastBuf[1];
   double mid   = midBuf[1];
   double slow  = slowBuf[1];
   double atr   = atrBuf[1];
   double close = iClose(_Symbol, PERIOD_CURRENT, 1);
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // All 3 MAs aligned bullish
   bool bullishAlign = fast > mid && mid > slow;
   // All 3 MAs aligned bearish
   bool bearishAlign = fast < mid && mid < slow;

   // Price near mid MA (pullback entry)
   bool nearMidBull = close >= mid - atr * PullbackZone && close <= mid + atr * PullbackZone && close > slow;
   bool nearMidBear = close >= mid - atr * PullbackZone && close <= mid + atr * PullbackZone && close < slow;

   // Price bounced off mid MA
   bool prevClose    = iClose(_Symbol, PERIOD_CURRENT, 2);
   bool bouncedUp    = prevClose < mid && close > mid;
   bool bouncedDown  = prevClose > mid && close < mid;

   if(bullishAlign && (nearMidBull || bouncedUp))
   {
      double sl   = mid - atr * ATR_SL_Mult;
      double tp   = ask + atr * ATR_TP_Mult;
      double lots = CalcLotSize(ask - sl);
      trade.Buy(lots, _Symbol, ask, sl, tp, "EA10 3MA Buy Pullback");
   }
   else if(bearishAlign && (nearMidBear || bouncedDown))
   {
      double sl   = mid + atr * ATR_SL_Mult;
      double tp   = bid - atr * ATR_TP_Mult;
      double lots = CalcLotSize(sl - bid);
      trade.Sell(lots, _Symbol, bid, sl, tp, "EA10 3MA Sell Pullback");
   }
}

void OnDeinit(const int reason) {}
