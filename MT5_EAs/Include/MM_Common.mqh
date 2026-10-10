//+------------------------------------------------------------------+
//| MM_Common.mqh - Shared money management & utility library       |
//+------------------------------------------------------------------+
#property copyright "MT5 Trading System"

//--- Shared inputs (declare in each EA, reference here)
//    RiskPercent, MaxDailyLoss, MaxTrades are expected per EA

//--- Calculate lot size based on SL distance
double MM_CalcLots(double slDistance, double riskPct, ulong magic)
{
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmt  = balance * riskPct / 100.0;
   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double lotStep  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(slDistance <= 0 || tickVal <= 0) return minLot;
   double lots = riskAmt / (slDistance / tickSize * tickVal);
   lots = MathFloor(lots / lotStep) * lotStep;
   return MathMax(minLot, MathMin(maxLot, lots));
}

//--- Check daily loss limit
bool MM_DailyLossOK(double &dayStart, double maxLossPct)
{
   static datetime lastDay = 0;
   datetime today = (datetime)(TimeCurrent() - TimeCurrent() % 86400);
   if(today != lastDay) { lastDay = today; dayStart = AccountInfoDouble(ACCOUNT_BALANCE); }
   double drawdown = (dayStart - AccountInfoDouble(ACCOUNT_BALANCE)) / dayStart * 100.0;
   return drawdown < maxLossPct;
}

//--- Count open trades by magic
int MM_CountTrades(ulong magic)
{
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
      if(PositionGetSymbol(i) == _Symbol && (ulong)PositionGetInteger(POSITION_MAGIC) == magic)
         count++;
   return count;
}

//--- Session filter
bool MM_InSession(int startH, int endH)
{
   int h = TimeHour(TimeCurrent());
   return (h >= startH && h < endH);
}

//--- ATR trailing stop
void MM_TrailATR(CTrade &trade, ulong magic, int atrHandle, double mult)
{
   double atrBuf[2]; ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(atrHandle, 0, 0, 2, atrBuf) < 2) return;
   double atr = atrBuf[1];
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(PositionGetSymbol(i) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != magic) continue;
      ulong  t   = PositionGetInteger(POSITION_TICKET);
      long   typ = PositionGetInteger(POSITION_TYPE);
      double sl  = PositionGetDouble(POSITION_SL);
      double tp  = PositionGetDouble(POSITION_TP);
      if(typ == POSITION_TYPE_BUY)
      { double nsl = SymbolInfoDouble(_Symbol, SYMBOL_BID) - atr * mult; if(nsl > sl + _Point) trade.PositionModify(t, nsl, tp); }
      else
      { double nsl = SymbolInfoDouble(_Symbol, SYMBOL_ASK) + atr * mult; if(sl == 0 || nsl < sl - _Point) trade.PositionModify(t, nsl, tp); }
   }
}

//--- Close all trades with magic
void MM_CloseAll(CTrade &trade, ulong magic)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(PositionGetSymbol(i) == _Symbol && (ulong)PositionGetInteger(POSITION_MAGIC) == magic)
         trade.PositionClose(PositionGetInteger(POSITION_TICKET));
}
