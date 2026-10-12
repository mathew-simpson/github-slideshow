//+------------------------------------------------------------------+
//|  EA11 - Grid Recovery System                                     |
//|  Strategy: Initial trend trade + grid recovery on adverse move   |
//|  Note: Use with caution - grid has inherent risk, strict limits  |
//+------------------------------------------------------------------+
#property copyright "MT5 Trading System"
#property version   "1.00"

#include <Trade\Trade.mqh>

input group "=== Initial Trade Settings ==="
input int    EMA_Period     = 50;
input int    ATR_Period     = 14;
input double ATR_SL_Mult    = 3.0;
input double ATR_TP_Mult    = 3.0;

input group "=== Grid Settings ==="
input double GridATRMult    = 0.75;   // Grid spacing as ATR multiple
input int    MaxGridLevels  = 3;      // Max recovery levels
input double GridLotMult    = 1.5;    // Lot size multiplier per level

input group "=== Risk Management ==="
input double InitRiskPct    = 0.5;    // Initial trade risk %
input double MaxDrawdownPct = 8.0;    // Hard stop entire grid
input double MaxDailyLoss   = 5.0;

input group "=== Session Filter ==="
input int    StartHour      = 7;
input int    EndHour        = 20;

CTrade trade;
int    emaHandle, atrHandle;
double emaBuf[], atrBuf[];
double dayStartBalance  = 0;
double gridStartBalance = 0;
bool   gridActive       = false;
int    gridDirection    = 0;   // 1 = long grid, -1 = short grid
int    gridLevel        = 0;
double gridNextPrice    = 0;
double gridBaseLot      = 0;

int OnInit()
{
   emaHandle = iMA(_Symbol, PERIOD_CURRENT, EMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   atrHandle = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);

   if(emaHandle == INVALID_HANDLE || atrHandle == INVALID_HANDLE)
   { Print("Indicator init failed"); return INIT_FAILED; }

   ArraySetAsSeries(emaBuf, true);
   ArraySetAsSeries(atrBuf, true);

   trade.SetExpertMagicNumber(10011);
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

bool MaxDrawdownExceeded()
{
   if(!gridActive) return false;
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double drawdown = (gridStartBalance - balance) / gridStartBalance * 100.0;
   return (drawdown >= MaxDrawdownPct);
}

void CloseAllGrid()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == 10011)
         trade.PositionClose(PositionGetInteger(POSITION_TICKET));
   }
   gridActive    = false;
   gridDirection = 0;
   gridLevel     = 0;
   gridNextPrice = 0;
}

int CountGridPositions()
{
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == 10011)
         count++;
   return count;
}

double CalcLotSize(double slPoints)
{
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmt  = balance * InitRiskPct / 100.0;
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
   static datetime lastDay = 0;
   datetime today = (datetime)(TimeCurrent() - TimeCurrent() % 86400);
   if(today != lastDay) { lastDay = today; dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE); }

   // Emergency close on max drawdown
   if(MaxDrawdownExceeded()) { CloseAllGrid(); return; }
   if(DailyLossExceeded())   { CloseAllGrid(); return; }

   if(CopyBuffer(emaHandle, 0, 0, 2, emaBuf) < 2) return;
   if(CopyBuffer(atrHandle, 0, 0, 2, atrBuf) < 2) return;

   double ema   = emaBuf[1];
   double atr   = atrBuf[1];
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double close = iClose(_Symbol, PERIOD_CURRENT, 1);

   // Initial trade entry
   if(!gridActive && IsTradingSession() && CountGridPositions() == 0)
   {
      static datetime lastBar = 0;
      datetime curBar = iTime(_Symbol, PERIOD_CURRENT, 0);
      if(curBar == lastBar) return;
      lastBar = curBar;

      bool bullTrend = close > ema;
      bool bearTrend = close < ema;

      double sl, tp, lots;
      if(bullTrend)
      {
         sl   = ask - atr * ATR_SL_Mult;
         tp   = ask + atr * ATR_TP_Mult;
         lots = CalcLotSize(ask - sl);
         gridBaseLot = lots;
         if(trade.Buy(lots, _Symbol, ask, sl, tp, "EA11 Grid Init Buy"))
         {
            gridActive    = true;
            gridDirection = 1;
            gridLevel     = 1;
            gridNextPrice = ask - atr * GridATRMult;
            gridStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
         }
      }
      else if(bearTrend)
      {
         sl   = bid + atr * ATR_SL_Mult;
         tp   = bid - atr * ATR_TP_Mult;
         lots = CalcLotSize(sl - bid);
         gridBaseLot = lots;
         if(trade.Sell(lots, _Symbol, bid, sl, tp, "EA11 Grid Init Sell"))
         {
            gridActive    = true;
            gridDirection = -1;
            gridLevel     = 1;
            gridNextPrice = bid + atr * GridATRMult;
            gridStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
         }
      }
      return;
   }

   // Grid recovery - add to position on adverse move
   if(gridActive && gridLevel < MaxGridLevels)
   {
      double gridLots = gridBaseLot * MathPow(GridLotMult, gridLevel);
      double minLot   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double maxLot   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
      double lotStep  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      gridLots = MathFloor(gridLots / lotStep) * lotStep;
      gridLots = MathMax(minLot, MathMin(maxLot, gridLots));

      if(gridDirection == 1 && bid <= gridNextPrice)
      {
         double sl = bid - atr * ATR_SL_Mult;
         double tp = bid + atr * ATR_TP_Mult;
         if(trade.Buy(gridLots, _Symbol, ask, sl, tp, "EA11 Grid Level " + IntegerToString(gridLevel + 1)))
         {
            gridLevel++;
            gridNextPrice = bid - atr * GridATRMult;
         }
      }
      else if(gridDirection == -1 && ask >= gridNextPrice)
      {
         double sl = ask + atr * ATR_SL_Mult;
         double tp = ask - atr * ATR_TP_Mult;
         if(trade.Sell(gridLots, _Symbol, bid, sl, tp, "EA11 Grid Level " + IntegerToString(gridLevel + 1)))
         {
            gridLevel++;
            gridNextPrice = ask + atr * GridATRMult;
         }
      }
   }

   // Check if all positions closed (TP or SL hit)
   if(gridActive && CountGridPositions() == 0)
   {
      gridActive    = false;
      gridDirection = 0;
      gridLevel     = 0;
   }
}

void OnDeinit(const int reason)
{
   if(MaxDrawdownExceeded()) CloseAllGrid();
}
