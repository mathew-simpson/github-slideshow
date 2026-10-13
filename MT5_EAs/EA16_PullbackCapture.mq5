//+------------------------------------------------------------------+
//|  EA16 - Pullback Capture (System 2)                              |
//|  Strategy: trade the pullback against a D1 trend, exit when the  |
//|  pullback ends. Runs alongside a multi-day trend-hold system.    |
//|  Rules, parameters and test windows: PULLBACK_SYSTEM_SPEC.md     |
//|  Attach to EURUSD H1 on a hedging account.                       |
//+------------------------------------------------------------------+
#property copyright "MT5 Trading System"
#property version   "1.00"

#include <Trade\Trade.mqh>
#include "Include/Portfolio.mqh"

#define EA16_MAGIC 10016

input group "=== D1 Trend Filter (fixed) ==="
input int    D1_TrendMA      = 50;    // D1 EMA period
input int    D1_SlopeBars    = 5;     // EMA must be higher (lower) than this many days ago
input double D1_MinADX       = 20.0;  // Minimum D1 ADX(14)

input group "=== Impulse Leg (fixed) ==="
input int    ImpulseLookback = 48;    // H1 bars searched for the leg
input int    FreshBars       = 12;    // Leg extreme must be within this many bars
input double MinLegATR       = 3.0;   // Minimum leg size in H1 ATR(14)

input group "=== Entry and Exit (optimised) ==="
input int    H1_FastMA       = 20;    // H1 EMA that marks pullback start and end
input double TargetRetrace   = 0.5;   // Target = this fraction of the leg retraced
input double SL_ATR_Buffer   = 0.5;   // Stop beyond the leg extreme, in ATR
input int    MaxHoldBars     = 24;    // Time stop in H1 bars

input group "=== Costs and Risk (fixed) ==="
input double MinRR           = 1.0;   // Skip if target distance < MinRR x stop distance
input int    MaxSpreadPoints = 20;    // Skip if spread is wider (points)
input double MaxSpreadFrac   = 0.10;  // Skip if spread > this fraction of target distance
input double RiskPercent     = 0.5;   // Risk at the stop, % of balance

input group "=== Session Filter (fixed) ==="
input int    StartHour       = 7;
input int    EndHour         = 20;

CTrade trade;
int    d1MaHandle, d1AdxHandle, h1MaHandle, atrHandle;
double lastLegExtreme = 0;            // One trade per impulse leg

int OnInit()
{
   if(_Period != PERIOD_H1)
   { Print("EA16 is specified for H1 only"); return INIT_PARAMETERS_INCORRECT; }

   d1MaHandle  = iMA(_Symbol, PERIOD_D1, D1_TrendMA, 0, MODE_EMA, PRICE_CLOSE);
   d1AdxHandle = iADX(_Symbol, PERIOD_D1, 14);
   h1MaHandle  = iMA(_Symbol, PERIOD_H1, H1_FastMA, 0, MODE_EMA, PRICE_CLOSE);
   atrHandle   = iATR(_Symbol, PERIOD_H1, 14);

   if(d1MaHandle == INVALID_HANDLE || d1AdxHandle == INVALID_HANDLE ||
      h1MaHandle == INVALID_HANDLE || atrHandle == INVALID_HANDLE)
   { Print("Indicator init failed"); return INIT_FAILED; }

   trade.SetExpertMagicNumber(10016);
   return INIT_SUCCEEDED;
}

//--- D1 trend on the last closed day: +1 up, -1 down, 0 none, -2 data not ready
int D1Trend()
{
   double ma[], adx[];
   ArraySetAsSeries(ma, true);
   ArraySetAsSeries(adx, true);
   if(CopyBuffer(d1MaHandle, 0, 1, D1_SlopeBars + 1, ma) < D1_SlopeBars + 1) return -2;
   if(CopyBuffer(d1AdxHandle, 0, 1, 1, adx) < 1) return -2;
   double close = iClose(_Symbol, PERIOD_D1, 1);
   if(close == 0) return -2;
   if(adx[0] < D1_MinADX) return 0;
   if(close > ma[0] && ma[0] > ma[D1_SlopeBars]) return  1;
   if(close < ma[0] && ma[0] < ma[D1_SlopeBars]) return -1;
   return 0;
}

//--- Our open position, if any. Returns false when there is none.
bool SelectOwnPosition()
{
   for(int i = 0; i < PositionsTotal(); i++)
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == EA16_MAGIC)
         return true;
   return false;
}

//--- Exits that are not stop or target: resumption, time, trend gone
void ManagePosition(int trend, const double &ema[], const double &cls[])
{
   ulong  ticket = PositionGetInteger(POSITION_TICKET);
   long   type   = PositionGetInteger(POSITION_TYPE);
   int    held   = iBarShift(_Symbol, PERIOD_H1, (datetime)PositionGetInteger(POSITION_TIME));

   // A sell is taken against an uptrend, a buy against a downtrend
   bool   isSell  = (type == POSITION_TYPE_SELL);
   bool   resumed = held >= 2 && (isSell ? cls[1] > ema[1] : cls[1] < ema[1]);
   bool   timeUp  = held >= MaxHoldBars;
   bool   trendGone = trend != -2 && trend != (isSell ? 1 : -1);

   if(resumed || timeUp || trendGone)
      trade.PositionClose(ticket);
}

void OnTick()
{
   PF_Update();
   static datetime lastBar = 0;
   datetime curBar = iTime(_Symbol, PERIOD_H1, 0);
   if(curBar == lastBar) return;
   lastBar = curBar;

   // Index 1 = last closed bar, 2 = the one before
   double ema[], cls[], atrBuf[];
   ArraySetAsSeries(ema, true);
   ArraySetAsSeries(cls, true);
   ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(h1MaHandle, 0, 0, 3, ema) < 3) return;
   if(CopyClose(_Symbol, PERIOD_H1, 0, 3, cls) < 3) return;
   if(CopyBuffer(atrHandle, 0, 1, 1, atrBuf) < 1) return;

   int trend = D1Trend();

   if(SelectOwnPosition())
   {
      ManagePosition(trend, ema, cls);
      return;
   }

   if(trend == 0 || trend == -2)              return;
   if(!MM_InSession(StartHour, EndHour))      return;

   // Impulse leg over the last ImpulseLookback closed bars, series order (0 = newest)
   double hi[], lo[];
   ArraySetAsSeries(hi, true);
   ArraySetAsSeries(lo, true);
   if(CopyHigh(_Symbol, PERIOD_H1, 1, ImpulseLookback, hi) < ImpulseLookback) return;
   if(CopyLow(_Symbol,  PERIOD_H1, 1, ImpulseLookback, lo) < ImpulseLookback) return;

   double atr = atrBuf[0];
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spread = ask - bid;
   if(atr <= 0 || spread > MaxSpreadPoints * _Point) return;

   if(trend == 1)
   {
      // Up-leg: fresh high, low taken from the older bars before it
      int iHigh = ArrayMaximum(hi, 0, ImpulseLookback);
      if(iHigh < 0 || iHigh >= FreshBars || iHigh + 1 >= ImpulseLookback) return;
      int iLow = ArrayMinimum(lo, iHigh + 1, ImpulseLookback - iHigh - 1);
      if(iLow < 0) return;
      double legHigh = hi[iHigh], legLow = lo[iLow], leg = legHigh - legLow;
      if(leg < MinLegATR * atr || legHigh == lastLegExtreme) return;

      // First close back below the fast EMA = pullback start
      if(!(cls[1] < ema[1] && cls[2] >= ema[2])) return;

      double tp = NormalizeDouble(legHigh - TargetRetrace * leg, _Digits);
      double sl = NormalizeDouble(legHigh + SL_ATR_Buffer * atr, _Digits);
      double tgtDist = bid - tp, slDist = sl - bid;
      if(tgtDist <= 0 || slDist <= 0 || tgtDist < MinRR * slDist) return;
      if(spread > MaxSpreadFrac * tgtDist) return;

      double lots = PF_Lots(ORDER_TYPE_SELL, bid, sl, RiskPercent, EA16_MAGIC);
      string cmt  = StringFormat("EA16 PB Sell sp=%d", (int)MathRound(spread / _Point));
      if(lots > 0 && trade.Sell(lots, _Symbol, bid, sl, tp, cmt)) lastLegExtreme = legHigh;
   }
   else if(trend == -1)
   {
      // Down-leg: fresh low, high taken from the older bars before it
      int iLow = ArrayMinimum(lo, 0, ImpulseLookback);
      if(iLow < 0 || iLow >= FreshBars || iLow + 1 >= ImpulseLookback) return;
      int iHigh = ArrayMaximum(hi, iLow + 1, ImpulseLookback - iLow - 1);
      if(iHigh < 0) return;
      double legLow = lo[iLow], legHigh = hi[iHigh], leg = legHigh - legLow;
      if(leg < MinLegATR * atr || legLow == lastLegExtreme) return;

      // First close back above the fast EMA = pullback start
      if(!(cls[1] > ema[1] && cls[2] <= ema[2])) return;

      double tp = NormalizeDouble(legLow + TargetRetrace * leg, _Digits);
      double sl = NormalizeDouble(legLow - SL_ATR_Buffer * atr, _Digits);
      double tgtDist = tp - ask, slDist = ask - sl;
      if(tgtDist <= 0 || slDist <= 0 || tgtDist < MinRR * slDist) return;
      if(spread > MaxSpreadFrac * tgtDist) return;

      double lots = PF_Lots(ORDER_TYPE_BUY, ask, sl, RiskPercent, EA16_MAGIC);
      string cmt  = StringFormat("EA16 PB Buy sp=%d", (int)MathRound(spread / _Point));
      if(lots > 0 && trade.Buy(lots, _Symbol, ask, sl, tp, cmt)) lastLegExtreme = legLow;
   }
}

void OnDeinit(const int reason) {}
