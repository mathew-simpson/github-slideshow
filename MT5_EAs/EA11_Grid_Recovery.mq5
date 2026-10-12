//+------------------------------------------------------------------+
//|  EA11 - Grid Recovery System                                     |
//|  Strategy: Initial trend trade + grid recovery on adverse move   |
//|  Note: Use with caution - grid has inherent risk, strict limits  |
//+------------------------------------------------------------------+
#property copyright "MT5 Trading System"
#property version   "1.00"

#include <Trade\Trade.mqh>
#include "Include/Portfolio.mqh"

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
input bool   UseEquityStops  = false; // true = daily and grid stops use equity (includes open P/L); false = realized balance (legacy)

input group "=== Session Filter ==="
input int    StartHour      = 7;
input int    EndHour        = 20;

CTrade trade;
int    emaHandle, atrHandle;
double emaBuf[], atrBuf[];
double dayStartBalance  = 0;
double gridStartBalance = 0;

// Balance the stops measure: realized (legacy) or equity (includes open grid P/L)
double StopMetric() { return AccountInfoDouble(UseEquityStops ? ACCOUNT_EQUITY : ACCOUNT_BALANCE); }
bool   gridActive       = false;
int    gridDirection    = 0;   // 1 = long grid, -1 = short grid
int    gridLevel        = 0;
double gridNextPrice    = 0;
double gridBaseLot      = 0;
double gridInitThrottle = 1.0;   // Throttle in force when gridBaseLot was sized at entry

int OnInit()
{
   emaHandle = iMA(_Symbol, PERIOD_CURRENT, EMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   atrHandle = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);

   if(emaHandle == INVALID_HANDLE || atrHandle == INVALID_HANDLE)
   { Print("Indicator init failed"); return INIT_FAILED; }

   ArraySetAsSeries(emaBuf, true);
   ArraySetAsSeries(atrBuf, true);

   trade.SetExpertMagicNumber(10011);
   dayStartBalance = StopMetric();
   return INIT_SUCCEEDED;
}

bool IsTradingSession()
{
   int hour = MM_Hour(TimeCurrent());
   return (hour >= StartHour && hour < EndHour);
}

bool DailyLossExceeded()
{
   double balance  = StopMetric();
   if(balance <= 0) return false;   // A zero or negative read is not a measured loss
   double drawdown = (dayStartBalance - balance) / dayStartBalance * 100.0;
   return (drawdown >= MaxDailyLoss);
}

bool MaxDrawdownExceeded()
{
   if(!gridActive) return false;
   double balance  = StopMetric();
   if(balance <= 0) return false;   // A zero or negative read is not a measured loss
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

void OnTick()
{
   PF_Update();
   static datetime lastDay = 0;
   datetime today = (datetime)(TimeCurrent() - TimeCurrent() % 86400);
   if(today != lastDay) { lastDay = today; dayStartBalance = StopMetric(); }

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
         lots = PF_Lots(ORDER_TYPE_BUY, ask, sl, InitRiskPct, 10011);
         gridBaseLot = lots;
         gridInitThrottle = PF_ThrottleFactor();
         if(lots > 0 && trade.Buy(lots, _Symbol, ask, sl, tp, "EA11 Grid Init Buy"))
         {
            gridActive    = true;
            gridDirection = 1;
            gridLevel     = 1;
            gridNextPrice = ask - atr * GridATRMult;
            gridStartBalance = StopMetric();
         }
      }
      else if(bearTrend)
      {
         sl   = bid + atr * ATR_SL_Mult;
         tp   = bid - atr * ATR_TP_Mult;
         lots = PF_Lots(ORDER_TYPE_SELL, bid, sl, InitRiskPct, 10011);
         gridBaseLot = lots;
         gridInitThrottle = PF_ThrottleFactor();
         if(lots > 0 && trade.Sell(lots, _Symbol, bid, sl, tp, "EA11 Grid Init Sell"))
         {
            gridActive    = true;
            gridDirection = -1;
            gridLevel     = 1;
            gridNextPrice = bid + atr * GridATRMult;
            gridStartBalance = StopMetric();
         }
      }
      return;
   }

   // Grid recovery - add to position on adverse move
   if(gridActive && gridLevel < MaxGridLevels)
   {
      double gridLots = gridBaseLot * MathPow(GridLotMult, gridLevel);

      if(gridDirection == 1 && bid <= gridNextPrice)
      {
         double sl = bid - atr * ATR_SL_Mult;
         double tp = bid + atr * ATR_TP_Mult;
         // gridBaseLot carries the entry-time throttle. Divide it out and apply the current one, so the throttle counts once.
         // PF_CapLots applies the allocation gate and caps
         double lots = PF_CapLots(ORDER_TYPE_BUY, ask, sl, gridLots * PF_ThrottleFactor() / gridInitThrottle, 10011);
         if(lots > 0 && trade.Buy(lots, _Symbol, ask, sl, tp, "EA11 Grid Level " + IntegerToString(gridLevel + 1)))
         {
            gridLevel++;
            gridNextPrice = bid - atr * GridATRMult;
         }
      }
      else if(gridDirection == -1 && ask >= gridNextPrice)
      {
         double sl = ask + atr * ATR_SL_Mult;
         double tp = ask - atr * ATR_TP_Mult;
         // gridBaseLot carries the entry-time throttle. Divide it out and apply the current one, so the throttle counts once.
         // PF_CapLots applies the allocation gate and caps
         double lots = PF_CapLots(ORDER_TYPE_SELL, bid, sl, gridLots * PF_ThrottleFactor() / gridInitThrottle, 10011);
         if(lots > 0 && trade.Sell(lots, _Symbol, bid, sl, tp, "EA11 Grid Level " + IntegerToString(gridLevel + 1)))
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
