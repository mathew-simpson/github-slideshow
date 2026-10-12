//+------------------------------------------------------------------+
//| EA13 - ADX Directional Movement System                          |
//| Buy when +DI crosses above -DI AND ADX rising above threshold   |
//+------------------------------------------------------------------+
#property version "1.00"
#include <Trade\Trade.mqh>
#include "Include/Portfolio.mqh"

input int    ADX_Period   = 14;   input double ADX_MinLevel  = 20.0;
input int    ATR_Period   = 14;   input double ATR_SL_Mult   = 2.0;
input double ATR_TP_Mult  = 3.0;  input double RiskPercent   = 1.0;
input double MaxDailyLoss = 5.0;  input int    MaxTrades     = 2;
input int    StartHour    = 7;    input int    EndHour       = 20;

CTrade trade;
int    adxH, atrH;
double adxBuf[], plusDI[], minusDI[], atrBuf[];
double dayStart = 0;

int OnInit()
{
   adxH = iADX(_Symbol, PERIOD_CURRENT, ADX_Period);
   atrH = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);
   if(adxH == INVALID_HANDLE || atrH == INVALID_HANDLE) return INIT_FAILED;
   ArraySetAsSeries(adxBuf, true); ArraySetAsSeries(plusDI, true);
   ArraySetAsSeries(minusDI, true); ArraySetAsSeries(atrBuf, true);
   trade.SetExpertMagicNumber(10013);
   dayStart = AccountInfoDouble(ACCOUNT_BALANCE);
   return INIT_SUCCEEDED;
}

void OnTick()
{
   PF_Update();
   static datetime lb = 0; datetime cb = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(cb == lb) return; lb = cb;
   if(!MM_DailyLossOK(dayStart, MaxDailyLoss)) return;
   if(!MM_InSession(StartHour, EndHour)) return;
   if(MM_CountTrades(10013) >= MaxTrades) return;
   if(CopyBuffer(adxH, 0, 0, 3, adxBuf)  < 3) return;
   if(CopyBuffer(adxH, 1, 0, 3, plusDI)  < 3) return;
   if(CopyBuffer(adxH, 2, 0, 3, minusDI) < 3) return;
   if(CopyBuffer(atrH, 0, 0, 2, atrBuf)  < 2) return;

   double adx = adxBuf[1], atr = atrBuf[1];
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   bool rising = adxBuf[1] > adxBuf[2];
   bool buySignal  = plusDI[2]  <= minusDI[2] && plusDI[1]  > minusDI[1] && adx > ADX_MinLevel && rising;
   bool sellSignal = plusDI[2]  >= minusDI[2] && plusDI[1]  < minusDI[1] && adx > ADX_MinLevel && rising;

   if(buySignal)
   { double sl = ask - atr*ATR_SL_Mult; double lots = PF_Lots(ORDER_TYPE_BUY, ask, sl, RiskPercent, 10013); if(lots > 0) trade.Buy(lots, _Symbol, ask, sl, ask+atr*ATR_TP_Mult, "EA13 Buy"); }
   else if(sellSignal)
   { double sl = bid + atr*ATR_SL_Mult; double lots = PF_Lots(ORDER_TYPE_SELL, bid, sl, RiskPercent, 10013); if(lots > 0) trade.Sell(lots, _Symbol, bid, sl, bid-atr*ATR_TP_Mult, "EA13 Sell"); }
}
void OnDeinit(const int reason) {}
