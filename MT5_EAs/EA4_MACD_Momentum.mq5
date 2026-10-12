//+------------------------------------------------------------------+
//|  EA4 - MACD Momentum                                             |
//|  Strategy: MACD histogram flip with trend confirmation           |
//|  Filter: ADX > 25 for trend strength                             |
//+------------------------------------------------------------------+
#property copyright "MT5 Trading System"
#property version   "1.00"

#include <Trade\Trade.mqh>

input group "=== Strategy Settings ==="
input int    MACD_Fast     = 12;
input int    MACD_Slow     = 26;
input int    MACD_Signal   = 9;
input int    ADX_Period    = 14;
input double ADX_MinLevel  = 25.0;
input int    ATR_Period    = 14;
input double ATR_SL_Mult   = 2.0;
input double ATR_TP_Mult   = 3.0;

input group "=== Risk Management ==="
input double RiskPercent   = 1.0;
input double MaxDailyLoss  = 5.0;
input int    MaxTrades     = 2;

input group "=== Session Filter ==="
input int    StartHour     = 7;
input int    EndHour       = 20;

CTrade trade;
int    macdHandle, adxHandle, atrHandle;
double macdMain[], macdSignal[], macdHist[], adxBuf[], atrBuf[];
double dayStartBalance = 0;

int OnInit()
{
   macdHandle = iMACD(_Symbol, PERIOD_CURRENT, MACD_Fast, MACD_Slow, MACD_Signal, PRICE_CLOSE);
   adxHandle  = iADX(_Symbol, PERIOD_CURRENT, ADX_Period);
   atrHandle  = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);

   if(macdHandle == INVALID_HANDLE || adxHandle == INVALID_HANDLE || atrHandle == INVALID_HANDLE)
   { Print("Indicator init failed"); return INIT_FAILED; }

   ArraySetAsSeries(macdMain,   true);
   ArraySetAsSeries(macdSignal, true);
   ArraySetAsSeries(macdHist,   true);
   ArraySetAsSeries(adxBuf,     true);
   ArraySetAsSeries(atrBuf,     true);

   trade.SetExpertMagicNumber(10004);
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
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == 10004)
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

   if(CopyBuffer(macdHandle, 0, 0, 4, macdMain)   < 4) return;
   if(CopyBuffer(macdHandle, 1, 0, 4, macdSignal) < 4) return;
   if(CopyBuffer(macdHandle, 2, 0, 4, macdHist)   < 4) return;
   if(CopyBuffer(adxHandle,  0, 0, 2, adxBuf)     < 2) return;
   if(CopyBuffer(atrHandle,  0, 0, 2, atrBuf)     < 2) return;

   double adx  = adxBuf[1];
   double atr  = atrBuf[1];
   double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // MACD histogram flip
   bool histFlipUp   = (macdHist[2] < 0 && macdHist[1] >= 0);
   bool histFlipDown = (macdHist[2] > 0 && macdHist[1] <= 0);

   // Trend filter - ADX shows momentum
   bool trendStrong = adx >= ADX_MinLevel;

   // MACD above/below zero line
   bool macdBullish = macdMain[1] > 0;
   bool macdBearish = macdMain[1] < 0;

   if(histFlipUp && trendStrong && macdBullish)
   {
      double sl   = ask - atr * ATR_SL_Mult;
      double tp   = ask + atr * ATR_TP_Mult;
      double lots = CalcLotSize(atr * ATR_SL_Mult);
      trade.Buy(lots, _Symbol, ask, sl, tp, "EA4 MACD Buy");
   }
   else if(histFlipDown && trendStrong && macdBearish)
   {
      double sl   = bid + atr * ATR_SL_Mult;
      double tp   = bid - atr * ATR_TP_Mult;
      double lots = CalcLotSize(atr * ATR_SL_Mult);
      trade.Sell(lots, _Symbol, bid, sl, tp, "EA4 MACD Sell");
   }
}

void OnDeinit(const int reason) {}
