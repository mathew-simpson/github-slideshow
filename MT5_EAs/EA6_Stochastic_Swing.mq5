//+------------------------------------------------------------------+
//|  EA6 - Stochastic Swing Trader                                   |
//|  Strategy: Stochastic %K/%D cross at extreme zones               |
//|  Filter: Higher timeframe trend alignment                         |
//+------------------------------------------------------------------+
#property copyright "MT5 Trading System"
#property version   "1.00"

#include <Trade\Trade.mqh>
#include "Include/Portfolio.mqh"

input group "=== Strategy Settings ==="
input int    Stoch_K        = 14;
input int    Stoch_D        = 3;
input int    Stoch_Slow     = 3;
input double OversoldLevel  = 20.0;
input double OverboughtLvl  = 80.0;
input ENUM_TIMEFRAMES HTF   = PERIOD_H4;  // Higher timeframe
input int    ATR_Period     = 14;
input double ATR_SL_Mult    = 1.8;
input double ATR_TP_Mult    = 2.5;

input group "=== Risk Management ==="
input double RiskPercent    = 1.0;
input double MaxDailyLoss   = 5.0;
input int    MaxTrades      = 2;

input group "=== Session Filter ==="
input int    StartHour      = 7;
input int    EndHour        = 20;

CTrade trade;
int    stochHandle, stochHTFHandle, atrHandle, maHTFHandle;
double stochK[], stochD[], stochHTFK[], atrBuf[], maHTF[];
double dayStartBalance = 0;

int OnInit()
{
   stochHandle    = iStochastic(_Symbol, PERIOD_CURRENT, Stoch_K, Stoch_D, Stoch_Slow, MODE_SMA, STO_LOWHIGH);
   stochHTFHandle = iStochastic(_Symbol, HTF, Stoch_K, Stoch_D, Stoch_Slow, MODE_SMA, STO_LOWHIGH);
   atrHandle      = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);
   maHTFHandle    = iMA(_Symbol, HTF, 50, 0, MODE_EMA, PRICE_CLOSE);

   if(stochHandle == INVALID_HANDLE || atrHandle == INVALID_HANDLE)
   { Print("Indicator init failed"); return INIT_FAILED; }

   ArraySetAsSeries(stochK,    true);
   ArraySetAsSeries(stochD,    true);
   ArraySetAsSeries(stochHTFK, true);
   ArraySetAsSeries(atrBuf,    true);
   ArraySetAsSeries(maHTF,     true);

   trade.SetExpertMagicNumber(10006);
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
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == 10006)
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

   if(CopyBuffer(stochHandle, 0, 0, 3, stochK)    < 3) return;
   if(CopyBuffer(stochHandle, 1, 0, 3, stochD)    < 3) return;
   if(CopyBuffer(stochHTFHandle, 0, 0, 2, stochHTFK) < 2) return;
   if(CopyBuffer(atrHandle,   0, 0, 2, atrBuf)    < 2) return;
   if(CopyBuffer(maHTFHandle, 0, 0, 2, maHTF)     < 2) return;

   double atr      = atrBuf[1];
   double ask      = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid      = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double closeHTF = iClose(_Symbol, HTF, 1);

   // HTF trend direction
   bool htfBullish = closeHTF > maHTF[1];
   bool htfBearish = closeHTF < maHTF[1];

   // HTF stoch not overbought/oversold (avoid trading at extremes on HTF)
   bool htfNotOverbought = stochHTFK[1] < 80.0;
   bool htfNotOversold   = stochHTFK[1] > 20.0;

   // LTF stochastic crosses
   bool kCrossUpFromOversold   = stochK[2] < stochD[2] && stochK[1] >= stochD[1] && stochK[2] < OversoldLevel;
   bool kCrossDownFromOverbought = stochK[2] > stochD[2] && stochK[1] <= stochD[1] && stochK[2] > OverboughtLvl;

   if(kCrossUpFromOversold && htfBullish && htfNotOverbought)
   {
      double sl   = ask - atr * ATR_SL_Mult;
      double tp   = ask + atr * ATR_TP_Mult;
      double lots = PF_Lots(ORDER_TYPE_BUY, ask, sl, RiskPercent, 10006);
      if(lots > 0) trade.Buy(lots, _Symbol, ask, sl, tp, "EA6 Stoch Buy");
   }
   else if(kCrossDownFromOverbought && htfBearish && htfNotOversold)
   {
      double sl   = bid + atr * ATR_SL_Mult;
      double tp   = bid - atr * ATR_TP_Mult;
      double lots = PF_Lots(ORDER_TYPE_SELL, bid, sl, RiskPercent, 10006);
      if(lots > 0) trade.Sell(lots, _Symbol, bid, sl, tp, "EA6 Stoch Sell");
   }
}

void OnDeinit(const int reason) {}
