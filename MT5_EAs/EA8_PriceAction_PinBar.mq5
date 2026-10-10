//+------------------------------------------------------------------+
//|  EA8 - Price Action Pin Bar Reversal                             |
//|  Strategy: Trade pin bars at key support/resistance levels       |
//|  Filter: 200 EMA trend direction, ATR size filter                |
//+------------------------------------------------------------------+
#property copyright "MT5 Trading System"
#property version   "1.00"

#include <Trade\Trade.mqh>

input group "=== Pin Bar Settings ==="
input double PinBodyRatio   = 0.33;   // Max body/range ratio
input double PinWickRatio   = 0.60;   // Min wick/range ratio
input int    EMA_Period     = 200;
input int    ATR_Period     = 14;
input double MinATR_Size    = 0.5;    // Min candle size as ATR multiple
input double ATR_SL_Mult    = 1.5;
input double ATR_TP_Mult    = 3.0;

input group "=== Risk Management ==="
input double RiskPercent    = 1.0;
input double MaxDailyLoss   = 4.0;
input int    MaxTrades      = 2;

input group "=== Session Filter ==="
input int    StartHour      = 7;
input int    EndHour        = 20;

CTrade trade;
int    emaHandle, atrHandle;
double emaBuf[], atrBuf[];
double dayStartBalance = 0;

int OnInit()
{
   emaHandle = iMA(_Symbol, PERIOD_CURRENT, EMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   atrHandle = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);

   if(emaHandle == INVALID_HANDLE || atrHandle == INVALID_HANDLE)
   { Print("Indicator init failed"); return INIT_FAILED; }

   ArraySetAsSeries(emaBuf, true);
   ArraySetAsSeries(atrBuf, true);

   trade.SetExpertMagicNumber(10008);
   dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   return INIT_SUCCEEDED;
}

bool IsPinBar(int bar, bool &isBullish)
{
   double open  = iOpen(_Symbol, PERIOD_CURRENT, bar);
   double high  = iHigh(_Symbol, PERIOD_CURRENT, bar);
   double low   = iLow(_Symbol, PERIOD_CURRENT, bar);
   double close = iClose(_Symbol, PERIOD_CURRENT, bar);

   double range    = high - low;
   if(range == 0) return false;

   double body     = MathAbs(close - open);
   double upperWick = high - MathMax(open, close);
   double lowerWick = MathMin(open, close) - low;

   double bodyRatio  = body / range;
   if(bodyRatio > PinBodyRatio) return false;

   // Bullish pin - long lower wick
   if(lowerWick / range >= PinWickRatio && upperWick < lowerWick)
   {
      isBullish = true;
      return true;
   }
   // Bearish pin - long upper wick
   if(upperWick / range >= PinWickRatio && upperWick > lowerWick)
   {
      isBullish = false;
      return true;
   }
   return false;
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
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == 10008)
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

   if(CopyBuffer(emaHandle, 0, 0, 2, emaBuf) < 2) return;
   if(CopyBuffer(atrHandle, 0, 0, 2, atrBuf) < 2) return;

   double ema   = emaBuf[1];
   double atr   = atrBuf[1];
   double close = iClose(_Symbol, PERIOD_CURRENT, 1);
   double range = iHigh(_Symbol, PERIOD_CURRENT, 1) - iLow(_Symbol, PERIOD_CURRENT, 1);
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // Check candle is big enough to trade
   if(range < atr * MinATR_Size) return;

   bool isBullishPin;
   if(!IsPinBar(1, isBullishPin)) return;

   bool trendUp   = close > ema;
   bool trendDown = close < ema;

   if(isBullishPin && trendUp)
   {
      double sl   = iLow(_Symbol, PERIOD_CURRENT, 1) - atr * ATR_SL_Mult;
      double tp   = ask + atr * ATR_TP_Mult;
      double lots = CalcLotSize(ask - sl);
      trade.Buy(lots, _Symbol, ask, sl, tp, "EA8 Bullish Pin");
   }
   else if(!isBullishPin && trendDown)
   {
      double sl   = iHigh(_Symbol, PERIOD_CURRENT, 1) + atr * ATR_SL_Mult;
      double tp   = bid - atr * ATR_TP_Mult;
      double lots = CalcLotSize(sl - bid);
      trade.Sell(lots, _Symbol, bid, sl, tp, "EA8 Bearish Pin");
   }
}

void OnDeinit(const int reason) {}
