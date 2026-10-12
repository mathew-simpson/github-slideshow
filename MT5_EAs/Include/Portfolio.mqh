//+------------------------------------------------------------------+
//| Portfolio.mqh - portfolio-level risk allocator shared by all EAs |
//|                                                                  |
//| Every EA sizes trades through PF_Lots(). It turns the EA's own   |
//| RiskPercent into a volume, then:                                 |
//|  - scales it by the EA's allocation (risk_mult) from             |
//|    Terminal\Common\Files\portfolio_allocation.csv, written by    |
//|    tester\portfolio_alloc.py from the walk-forward leaderboard;  |
//|    EAs without an active row do not trade on a live account     |
//|  - shrinks it while the account is in drawdown and blocks new    |
//|    entries past the halt drawdown or the daily loss limit        |
//|  - caps it so total open risk, risk on each currency, position   |
//|    count and margin use stay inside the account-wide limits      |
//| A volume below the broker minimum is skipped, never rounded up.  |
//+------------------------------------------------------------------+
#property copyright "MT5 Trading System"
#include "MM_Common.mqh"

input group "=== Portfolio Allocator ==="
input bool   PF_Enabled            = true;   // Size trades through the portfolio allocator
input string PF_AllocFile          = "portfolio_allocation.csv"; // File in Terminal\Common\Files
input bool   PF_RequireAlloc       = true;   // Live: trade only if this EA has an active row
input bool   PF_UseAllocInTester   = false;  // Apply the allocation file in the Strategy Tester
input double PF_MaxOpenRiskPct     = 6.0;    // Max open risk across all EAs, % of equity
input double PF_MaxCurrencyRiskPct = 3.0;    // Max risk long or short one currency, % of equity
input int    PF_MaxPositions       = 12;     // Max open positions on the account
input double PF_MaxMarginPct       = 30.0;   // Max margin in use, % of equity
input double PF_ThrottleDDPct      = 8.0;    // Drawdown from peak where trade risk starts shrinking
input double PF_HaltDDPct          = 15.0;   // Drawdown from peak that blocks new entries
input double PF_DailyLossPct       = 4.0;    // Account loss today that blocks new entries
input double PF_NoSLRiskPct        = 2.0;    // Risk assumed for a position without a stop loss

#define PF_GV_PEAK  "PF_PeakEquity"
#define PF_GV_DAY   "PF_Day"
#define PF_GV_DAYEQ "PF_DayStartEquity"
#define PF_GV_HALT  "PF_Halt"

struct PFAlloc
{
   long   magic;
   string symbol;
   double mult;
};

PFAlloc  pf_alloc[];
bool     pf_allocLoaded = false;
datetime pf_allocCheck  = 0;
datetime pf_allocMtime  = 0;

bool PF_InTester()
{
   return MQLInfoInteger(MQL_TESTER) != 0 || MQLInfoInteger(MQL_OPTIMIZATION) != 0;
}

//--- Strategy Tester runs size exactly as the EA did before the allocator, so
//    walk-forward results stay comparable and do not depend on terminal state
//    (global variables) left by earlier runs. PF_UseAllocInTester opts out.
bool PF_Bypass()
{
   return PF_InTester() && !PF_UseAllocInTester;
}

//--- Rate-limited log so a blocked EA does not flood the journal
void PF_Log(long magic, string msg)
{
   static string   lastMsg  = "";
   static datetime lastTime = 0;
   string full = "PF[" + IntegerToString(magic) + "] " + msg;
   if(full == lastMsg && TimeCurrent() - lastTime < 3600) return;
   lastMsg = full; lastTime = TimeCurrent();
   Print(full);
}

//--- Track peak equity and start-of-day equity, shared by every EA on the terminal
void PF_Update()
{
   if(PF_Bypass()) return;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(!GlobalVariableCheck(PF_GV_PEAK) || eq > GlobalVariableGet(PF_GV_PEAK))
      GlobalVariableSet(PF_GV_PEAK, eq);
   datetime now   = TimeCurrent();
   double   today = (double)(now - now % 86400);
   if(!GlobalVariableCheck(PF_GV_DAY) || GlobalVariableGet(PF_GV_DAY) != today)
   {
      GlobalVariableSet(PF_GV_DAY, today);
      GlobalVariableSet(PF_GV_DAYEQ, eq);
   }
}

double PF_DrawdownPct()
{
   double peak = GlobalVariableCheck(PF_GV_PEAK) ? GlobalVariableGet(PF_GV_PEAK) : 0.0;
   double eq   = AccountInfoDouble(ACCOUNT_EQUITY);
   return peak > 0 ? (peak - eq) / peak * 100.0 : 0.0;
}

double PF_DayLossPct()
{
   double d0 = GlobalVariableCheck(PF_GV_DAYEQ) ? GlobalVariableGet(PF_GV_DAYEQ) : 0.0;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   return d0 > 0 ? (d0 - eq) / d0 * 100.0 : 0.0;
}

bool PF_Halted()
{
   return GlobalVariableCheck(PF_GV_HALT) && GlobalVariableGet(PF_GV_HALT) > 0;
}

//--- Empty string when new entries are allowed
string PF_HaltReason()
{
   if(PF_Halted())                         return "halted by Portfolio Guard";
   if(PF_DrawdownPct() >= PF_HaltDDPct)    return "portfolio drawdown " + DoubleToString(PF_DrawdownPct(), 1) + "%";
   if(PF_DayLossPct()  >= PF_DailyLossPct) return "daily loss " + DoubleToString(PF_DayLossPct(), 1) + "%";
   return "";
}

//--- Allocation file: ea,magic,symbol,risk_mult,weight,status (symbol "*" = any)
void PF_LoadAlloc()
{
   if(pf_allocCheck > 0 && TimeLocal() - pf_allocCheck < 60) return;
   pf_allocCheck = TimeLocal();
   if(!FileIsExist(PF_AllocFile, FILE_COMMON))
   {
      ArrayResize(pf_alloc, 0);
      pf_allocLoaded = false;
      return;
   }
   int h = FileOpen(PF_AllocFile, FILE_READ | FILE_CSV | FILE_ANSI | FILE_COMMON | FILE_SHARE_READ | FILE_SHARE_WRITE, ',');
   if(h == INVALID_HANDLE) return;   // keep the table we already have
   datetime mt = (datetime)FileGetInteger(h, FILE_MODIFY_DATE);
   if(pf_allocLoaded && mt == pf_allocMtime) { FileClose(h); return; }

   ArrayResize(pf_alloc, 0);
   bool header = true;
   while(!FileIsEnding(h))
   {
      string cols[];
      int n = 0;
      do
      {
         ArrayResize(cols, n + 1);
         cols[n] = FileReadString(h);
         StringTrimLeft(cols[n]); StringTrimRight(cols[n]);
         n++;
      }
      while(!FileIsLineEnding(h) && !FileIsEnding(h));
      if(header) { header = false; continue; }
      if(n < 6 || cols[1] == "") continue;
      int k = ArraySize(pf_alloc);
      ArrayResize(pf_alloc, k + 1);
      pf_alloc[k].magic  = StringToInteger(cols[1]);
      pf_alloc[k].symbol = cols[2];
      pf_alloc[k].mult   = (cols[5] == "active") ? MathMax(0.0, StringToDouble(cols[3])) : 0.0;
   }
   FileClose(h);
   pf_allocMtime  = mt;
   pf_allocLoaded = true;
   Print("PF: loaded ", ArraySize(pf_alloc), " allocation rows from Common\\Files\\", PF_AllocFile);
}

//--- Risk multiplier for this EA on this symbol (0 = not allocated)
double PF_RiskMult(long magic, string sym)
{
   if(PF_InTester() && !PF_UseAllocInTester) return 1.0;
   PF_LoadAlloc();
   if(pf_allocLoaded)
      for(int i = 0; i < ArraySize(pf_alloc); i++)
         if(pf_alloc[i].magic == magic && (pf_alloc[i].symbol == "*" || pf_alloc[i].symbol == sym))
            return pf_alloc[i].mult;
   return PF_RequireAlloc ? 0.0 : 1.0;
}

//--- Money lost if a trade of this volume runs from price to its stop
double PF_TradeRisk(string sym, ENUM_ORDER_TYPE type, double volume, double price, double sl)
{
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(sl <= 0) return eq * PF_NoSLRiskPct / 100.0;
   double pnl = 0;
   if(!OrderCalcProfit(type, sym, volume, price, sl, pnl)) return eq * PF_NoSLRiskPct / 100.0;
   return pnl < 0 ? -pnl : 0.0;
}

//--- Remaining risk of the currently selected position (current price to stop)
double PF_SelectedPositionRisk()
{
   ENUM_ORDER_TYPE ot = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   return PF_TradeRisk(PositionGetString(POSITION_SYMBOL), ot, PositionGetDouble(POSITION_VOLUME),
                       PositionGetDouble(POSITION_PRICE_CURRENT), PositionGetDouble(POSITION_SL));
}

//--- Which currency a trade is long and which it is short. CFDs whose base and
//    profit currency match (indices, some metals) count as exposure to the symbol itself.
void PF_CurrencyLegs(string sym, int dir, string &longCcy, string &shortCcy)
{
   string base  = SymbolInfoString(sym, SYMBOL_CURRENCY_BASE);
   string quote = SymbolInfoString(sym, SYMBOL_CURRENCY_PROFIT);
   if(base == "" || base == quote) { base = sym; quote = ""; }
   if(dir > 0) { longCcy = base;  shortCcy = quote; }
   else        { longCcy = quote; shortCcy = base;  }
}

double PF_OpenRisk(long magic = -1)
{
   double total = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) == 0) continue;
      if(magic >= 0 && PositionGetInteger(POSITION_MAGIC) != magic) continue;
      total += PF_SelectedPositionRisk();
   }
   return total;
}

//--- Open risk that is long (side > 0) or short (side < 0) the given currency
double PF_CurrencyRisk(string ccy, int side)
{
   if(ccy == "") return 0.0;
   double total = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) == 0) continue;
      int dir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      string lc, sc;
      PF_CurrencyLegs(PositionGetString(POSITION_SYMBOL), dir, lc, sc);
      if((side > 0 && lc == ccy) || (side < 0 && sc == ccy))
         total += PF_SelectedPositionRisk();
   }
   return total;
}

//--- Floor to the volume step and clamp to broker min/max (original EA behaviour)
double PF_ClampLots(string sym, double lots)
{
   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   double mn   = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double mx   = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   if(step <= 0) step = 0.01;
   lots = MathFloor(lots / step) * step;
   return MathMax(mn, MathMin(mx, lots));
}

//--- Floor to the volume step; 0 when below the broker minimum
double PF_NormalizeLots(string sym, double lots)
{
   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   double mn   = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double mx   = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   if(step <= 0) step = 0.01;
   lots = MathFloor(lots / step + 1e-9) * step;
   if(mx > 0) lots = MathMin(lots, mx);
   if(lots < mn || lots <= 0) return 0.0;
   int digits = (int)MathMax(0, MathCeil(-MathLog10(step) - 1e-9));
   return NormalizeDouble(lots, digits);
}

//--- Largest volume up to wantLots that the account-wide limits allow. 0 = skip the trade.
double PF_CapLots(ENUM_ORDER_TYPE type, double entry, double sl, double wantLots, long magic, string sym = "")
{
   if(sym == "") sym = _Symbol;
   if(!PF_Enabled || PF_Bypass()) return PF_ClampLots(sym, wantLots);
   PF_Update();
   string why = PF_HaltReason();
   if(why != "") { PF_Log(magic, "entry blocked: " + why); return 0.0; }
   if(PositionsTotal() >= PF_MaxPositions) { PF_Log(magic, "entry blocked: position limit"); return 0.0; }

   double riskPerLot = PF_TradeRisk(sym, type, 1.0, entry, sl);
   if(riskPerLot <= 0) return 0.0;
   double eq   = AccountInfoDouble(ACCOUNT_EQUITY);
   double lots = wantLots;

   lots = MathMin(lots, (eq * PF_MaxOpenRiskPct / 100.0 - PF_OpenRisk()) / riskPerLot);

   string lc, sc;
   PF_CurrencyLegs(sym, type == ORDER_TYPE_BUY ? 1 : -1, lc, sc);
   double capC = eq * PF_MaxCurrencyRiskPct / 100.0;
   lots = MathMin(lots, (capC - PF_CurrencyRisk(lc, 1)) / riskPerLot);
   if(sc != "") lots = MathMin(lots, (capC - PF_CurrencyRisk(sc, -1)) / riskPerLot);

   double marginPerLot = 0;
   if(OrderCalcMargin(type, sym, 1.0, entry, marginPerLot) && marginPerLot > 0)
      lots = MathMin(lots, (eq * PF_MaxMarginPct / 100.0 - AccountInfoDouble(ACCOUNT_MARGIN)) / marginPerLot);

   double out = PF_NormalizeLots(sym, MathMax(0.0, lots));
   if(out <= 0) PF_Log(magic, "entry skipped: portfolio limits leave no room on " + sym);
   return out;
}

//--- Volume for a new trade risking riskPct of equity (before allocation and throttle)
double PF_Lots(ENUM_ORDER_TYPE type, double entry, double sl, double riskPct, long magic, string sym = "")
{
   if(sym == "") sym = _Symbol;
   if(!PF_Enabled || PF_Bypass()) return MM_CalcLots(MathAbs(entry - sl), riskPct, (ulong)magic);

   double mult = PF_RiskMult(magic, sym);
   if(mult <= 0) { PF_Log(magic, "no active allocation for " + sym + " in " + PF_AllocFile); return 0.0; }

   PF_Update();
   double dd = PF_DrawdownPct(), throttle = 1.0;
   if(dd > PF_ThrottleDDPct && PF_HaltDDPct > PF_ThrottleDDPct)
      throttle = MathMax(0.25, 1.0 - (dd - PF_ThrottleDDPct) / (PF_HaltDDPct - PF_ThrottleDDPct));

   double riskPerLot = PF_TradeRisk(sym, type, 1.0, entry, sl);
   if(riskPerLot <= 0) return 0.0;
   double riskMoney = AccountInfoDouble(ACCOUNT_EQUITY) * riskPct * mult * throttle / 100.0;
   return PF_CapLots(type, entry, sl, riskMoney / riskPerLot, magic, sym);
}
