//+------------------------------------------------------------------+
//| EA14 - CCI Extremes + Trend                                     |
//| CCI re-crossing oversold/overbought levels, 200 EMA trend filter|
//| No divergence check is implemented                              |
//+------------------------------------------------------------------+
#property version "1.00"
#include <Trade\Trade.mqh>
#include "Include/Portfolio.mqh"

input int    CCI_Period   = 20;   input double CCI_OB        = 100.0;
input double CCI_OS       = -100.0; input int  ATR_Period    = 14;
input double ATR_SL_Mult  = 1.8;  input double ATR_TP_Mult   = 2.5;
input double RiskPercent  = 1.0;  input double MaxDailyLoss  = 5.0;
input int    MaxTrades    = 2;    input int    StartHour     = 7;
input int    EndHour      = 20;

CTrade trade;
int    cciH, emaH, atrH;
double cciBuf[], emaBuf[], atrBuf[];
double dayStart = 0;

int OnInit()
{
   cciH = iCCI(_Symbol, PERIOD_CURRENT, CCI_Period, PRICE_TYPICAL);
   emaH = iMA(_Symbol, PERIOD_CURRENT, 200, 0, MODE_EMA, PRICE_CLOSE);
   atrH = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);
   if(cciH==INVALID_HANDLE||emaH==INVALID_HANDLE||atrH==INVALID_HANDLE) return INIT_FAILED;
   ArraySetAsSeries(cciBuf,true); ArraySetAsSeries(emaBuf,true); ArraySetAsSeries(atrBuf,true);
   trade.SetExpertMagicNumber(10014);
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
   if(MM_CountTrades(10014) >= MaxTrades) return;
   if(CopyBuffer(cciH, 0, 0, 4, cciBuf) < 4) return;
   if(CopyBuffer(emaH, 0, 0, 2, emaBuf) < 2) return;
   if(CopyBuffer(atrH, 0, 0, 2, atrBuf) < 2) return;

   double atr   = atrBuf[1], ema = emaBuf[1];
   double close = iClose(_Symbol, PERIOD_CURRENT, 1);
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // CCI crosses back from extreme
   bool buySignal  = cciBuf[2] < CCI_OS && cciBuf[1] >= CCI_OS && close > ema;
   bool sellSignal = cciBuf[2] > CCI_OB && cciBuf[1] <= CCI_OB && close < ema;

   if(buySignal)
   { double sl = ask-atr*ATR_SL_Mult; double lots = PF_Lots(ORDER_TYPE_BUY, ask, sl, RiskPercent, 10014); if(lots > 0) trade.Buy(lots, _Symbol,ask,sl,ask+atr*ATR_TP_Mult,"EA14 Buy"); }
   else if(sellSignal)
   { double sl = bid+atr*ATR_SL_Mult; double lots = PF_Lots(ORDER_TYPE_SELL, bid, sl, RiskPercent, 10014); if(lots > 0) trade.Sell(lots, _Symbol,bid,sl,bid-atr*ATR_TP_Mult,"EA14 Sell"); }
}
void OnDeinit(const int reason) {}
