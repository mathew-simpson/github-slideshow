//+------------------------------------------------------------------+
//|  EA5 - Ichimoku Trend Following                                  |
//|  Strategy: Price above/below cloud, Tenkan/Kijun cross           |
//|  Filter: Chikou span confirms direction                          |
//+------------------------------------------------------------------+
#property copyright "MT5 Trading System"
#property version   "1.00"

#include <Trade\Trade.mqh>
#include "Include/Portfolio.mqh"

input group "=== Ichimoku Settings ==="
input int    Tenkan_Period  = 9;
input int    Kijun_Period   = 26;
input int    Senkou_Period  = 52;
input int    ATR_Period     = 14;
input double ATR_SL_Mult    = 2.0;
input double ATR_TP_Mult    = 3.0;

input group "=== Risk Management ==="
input double RiskPercent    = 1.0;
input double MaxDailyLoss   = 5.0;
input int    MaxTrades      = 1;

input group "=== Session Filter ==="
input int    StartHour      = 7;
input int    EndHour        = 20;

CTrade trade;
int    ichHandle, atrHandle;
double tenkan[], kijun[], senkouA[], senkouB[], chikou[], atrBuf[];
double dayStartBalance = 0;

int OnInit()
{
   ichHandle = iIchimoku(_Symbol, PERIOD_CURRENT, Tenkan_Period, Kijun_Period, Senkou_Period);
   atrHandle = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);

   if(ichHandle == INVALID_HANDLE || atrHandle == INVALID_HANDLE)
   { Print("Indicator init failed"); return INIT_FAILED; }

   ArraySetAsSeries(tenkan,  true);
   ArraySetAsSeries(kijun,   true);
   ArraySetAsSeries(senkouA, true);
   ArraySetAsSeries(senkouB, true);
   ArraySetAsSeries(chikou,  true);
   ArraySetAsSeries(atrBuf,  true);

   trade.SetExpertMagicNumber(10005);
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
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == 10005)
         count++;
   return count;
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

   int lookback = Kijun_Period + 2;
   if(CopyBuffer(ichHandle, 0, 0, lookback, tenkan)  < lookback) return;
   if(CopyBuffer(ichHandle, 1, 0, lookback, kijun)   < lookback) return;
   if(CopyBuffer(ichHandle, 2, 0, lookback, senkouA) < lookback) return;
   if(CopyBuffer(ichHandle, 3, 0, lookback, senkouB) < lookback) return;
   if(CopyBuffer(ichHandle, 4, 0, lookback, chikou)  < lookback) return;
   if(CopyBuffer(atrHandle, 0, 0, 2, atrBuf)         < 2)        return;

   double close1    = iClose(_Symbol, PERIOD_CURRENT, 1);
   double cloudTop1 = MathMax(senkouA[1], senkouB[1]);
   double cloudBot1 = MathMin(senkouA[1], senkouB[1]);
   double atr       = atrBuf[1];
   double ask       = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid       = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // Tenkan / Kijun cross
   bool tkCrossUp   = tenkan[2] <= kijun[2] && tenkan[1] > kijun[1];
   bool tkCrossDown = tenkan[2] >= kijun[2] && tenkan[1] < kijun[1];

   // Price above/below cloud
   bool priceAboveCloud = close1 > cloudTop1;
   bool priceBelowCloud = close1 < cloudBot1;

   // Chikou above/below price 26 bars ago
   double priceChikou = iClose(_Symbol, PERIOD_CURRENT, Kijun_Period + 1);
   bool chikouBull = chikou[Kijun_Period] > priceChikou;
   bool chikouBear = chikou[Kijun_Period] < priceChikou;

   if(tkCrossUp && priceAboveCloud && chikouBull)
   {
      double sl   = ask - atr * ATR_SL_Mult;
      double tp   = ask + atr * ATR_TP_Mult;
      double lots = PF_Lots(ORDER_TYPE_BUY, ask, sl, RiskPercent, 10005);
      if(lots > 0) trade.Buy(lots, _Symbol, ask, sl, tp, "EA5 Ichimoku Buy");
   }
   else if(tkCrossDown && priceBelowCloud && chikouBear)
   {
      double sl   = bid + atr * ATR_SL_Mult;
      double tp   = bid - atr * ATR_TP_Mult;
      double lots = PF_Lots(ORDER_TYPE_SELL, bid, sl, RiskPercent, 10005);
      if(lots > 0) trade.Sell(lots, _Symbol, bid, sl, tp, "EA5 Ichimoku Sell");
   }
}

void OnDeinit(const int reason) {}
