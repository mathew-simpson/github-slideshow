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
//| A trade whose stop or margin cannot be priced is skipped too.    |
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
input double PF_NoSLRiskPct        = 2.0;    // Risk assumed for an open position without a stop loss

//--- Terminal global variables belong to the terminal, not the account, so every key carries
//    the login. Deposits and withdrawals are summed into PF_NetFlow and taken out of equity
//    before the peak and the day start are compared, so they never count as trading losses.
#define PF_GV_PEAK  "PF_PeakEquity"
#define PF_GV_DAY   "PF_Day"
#define PF_GV_DAYEQ "PF_DayStartEquity"
#define PF_GV_HALT  "PF_Halt"
#define PF_GV_FLOW  "PF_NetFlow"
#define PF_GV_FLOWT "PF_FlowTime"
#define PF_GV_FLOWK "PF_FlowTicket"

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

//--- Global variable name for this login
string PF_Key(string base)
{
   return base + "_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));
}

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

//--- Deposits and withdrawals are balance operations. Fees, commissions and swaps stay
//    in equity on purpose, so they still count as losses.
bool PF_IsCashFlow(ENUM_DEAL_TYPE dealType)
{
   return dealType == DEAL_TYPE_BALANCE;
}

//--- Highest deal ticket in the account history. Used as the baseline on first run,
//    so deposits made before the guard first ran are not counted as flows.
ulong PF_LastDealTicket(datetime now, bool &ok)
{
   ulong last = 0;
   ok = HistorySelect(0, now);
   if(!ok) return 0;
   int n = HistoryDealsTotal();
   for(int i = 0; i < n; i++)
   {
      ulong t = HistoryDealGetTicket(i);
      if(t > last) last = t;
   }
   return last;
}

//--- Add the deposits and withdrawals made since the last sync to PF_NetFlow.
//    Deal tickets rise through the account history, so a ticket above the stored one is new.
//    Synced at most once a second unless force is set. Halt and entry decisions always force it.
void PF_SyncFlows(bool force)
{
   static datetime lastSync = 0;
   datetime now = TimeCurrent();
   if(!force && now - lastSync < 1) return;
   lastSync = now;

   string kf = PF_Key(PF_GV_FLOW), kt = PF_Key(PF_GV_FLOWT), kk = PF_Key(PF_GV_FLOWK);
   if(!GlobalVariableCheck(kk))             // first run for this login: start the baseline here
   {
      bool ok = false;
      ulong base = PF_LastDealTicket(now, ok);
      if(!ok) return;                       // history not readable yet: try again on the next sync
      GlobalVariableSet(kk, (double)base);
      GlobalVariableSet(kt, (double)now);
      GlobalVariableSet(kf, 0.0);
      return;
   }
   datetime from = (datetime)GlobalVariableGet(kt);
   ulong    seen = (ulong)GlobalVariableGet(kk);
   if(!HistorySelect(from, now)) return;

   double flow = 0.0;
   ulong  top  = seen;
   int    n    = HistoryDealsTotal();
   for(int i = 0; i < n; i++)
   {
      ulong t = HistoryDealGetTicket(i);
      if(t == 0 || t <= seen) continue;
      if(t > top) top = t;
      if(PF_IsCashFlow((ENUM_DEAL_TYPE)HistoryDealGetInteger(t, DEAL_TYPE)))
         flow += HistoryDealGetDouble(t, DEAL_PROFIT);
   }
   GlobalVariableSet(kf, GlobalVariableCheck(kf) ? GlobalVariableGet(kf) + flow : flow);
   GlobalVariableSet(kk, (double)top);
   GlobalVariableSet(kt, (double)now);
}

//--- Deposits and withdrawals since the baseline
double PF_NetFlow()
{
   string k = PF_Key(PF_GV_FLOW);
   return GlobalVariableCheck(k) ? GlobalVariableGet(k) : 0.0;
}

//--- Equity with deposits and withdrawals taken out. Used by the guard, not for sizing.
double PF_AdjEquity()
{
   return AccountInfoDouble(ACCOUNT_EQUITY) - PF_NetFlow();
}

//--- Track peak and start-of-day trading equity, shared by every EA on this login.
//    A zero or negative sample is not recorded, so a bad read cannot move the peak or the day start.
void PF_Update(bool force = false)
{
   if(PF_Bypass()) return;
   PF_SyncFlows(force);
   double adj = PF_AdjEquity();
   if(adj <= 0) return;

   string kp = PF_Key(PF_GV_PEAK), kd = PF_Key(PF_GV_DAY), ke = PF_Key(PF_GV_DAYEQ);
   if(!GlobalVariableCheck(kp) || adj > GlobalVariableGet(kp))
      GlobalVariableSet(kp, adj);
   datetime now   = TimeCurrent();
   double   today = (double)(now - now % 86400);
   if(!GlobalVariableCheck(kd) || GlobalVariableGet(kd) != today || GlobalVariableGet(ke) <= 0)
   {
      GlobalVariableSet(kd, today);
      GlobalVariableSet(ke, adj);
   }
}

double PF_DrawdownPct()
{
   string kp   = PF_Key(PF_GV_PEAK);
   double peak = GlobalVariableCheck(kp) ? GlobalVariableGet(kp) : 0.0;
   double eq   = PF_AdjEquity();
   return peak > 0 ? (peak - eq) / peak * 100.0 : 0.0;
}

double PF_DayLossPct()
{
   string ke = PF_Key(PF_GV_DAYEQ);
   double d0 = GlobalVariableCheck(ke) ? GlobalVariableGet(ke) : 0.0;
   double eq = PF_AdjEquity();
   return d0 > 0 ? (d0 - eq) / d0 * 100.0 : 0.0;
}

//--- Size multiplier from drawdown: 1.0 up to the throttle level, falling to 0.25 at the halt level
double PF_ThrottleFactor()
{
   if(PF_Bypass() || !PF_Enabled) return 1.0;
   double dd = PF_DrawdownPct();
   if(dd > PF_ThrottleDDPct && PF_HaltDDPct > PF_ThrottleDDPct)
      return MathMax(0.25, 1.0 - (dd - PF_ThrottleDDPct) / (PF_HaltDDPct - PF_ThrottleDDPct));
   return 1.0;
}

bool PF_Halted()
{
   string k = PF_Key(PF_GV_HALT);
   return GlobalVariableCheck(k) && GlobalVariableGet(k) > 0;
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

//--- Money lost if a trade of this volume runs from price to its stop.
//    ok = false when there is no stop or the broker cannot price the trade. New trades must not be sized then.
double PF_TradeRisk(string sym, ENUM_ORDER_TYPE type, double volume, double price, double sl, bool &ok)
{
   ok = false;
   if(sl <= 0) return 0.0;
   double pnl = 0;
   if(!OrderCalcProfit(type, sym, volume, price, sl, pnl)) return 0.0;
   ok = true;
   return pnl < 0 ? -pnl : 0.0;
}

//--- Risk of an open position from its current price to its stop. A position with no stop,
//    or one that cannot be priced, is counted at PF_NoSLRiskPct so the open-risk caps stay conservative.
double PF_SelectedPositionRisk()
{
   ENUM_ORDER_TYPE ot = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   bool ok = false;
   double r = PF_TradeRisk(PositionGetString(POSITION_SYMBOL), ot, PositionGetDouble(POSITION_VOLUME),
                           PositionGetDouble(POSITION_PRICE_CURRENT), PositionGetDouble(POSITION_SL), ok);
   if(!ok) return AccountInfoDouble(ACCOUNT_EQUITY) * PF_NoSLRiskPct / 100.0;
   return r;
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

//--- Floor to the volume step and clamp to broker min/max (original EA behaviour, tester bypass only)
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
//    Fails closed: the trade is skipped when the allocation, the halt, the stop or the margin cannot be checked.
double PF_CapLots(ENUM_ORDER_TYPE type, double entry, double sl, double wantLots, long magic, string sym = "")
{
   if(sym == "") sym = _Symbol;
   if(!PF_Enabled || PF_Bypass()) return PF_ClampLots(sym, wantLots);
   PF_Update(true);
   string why = PF_HaltReason();
   if(why != "") { PF_Log(magic, "entry blocked: " + why); return 0.0; }
   if(PF_RiskMult(magic, sym) <= 0) { PF_Log(magic, "entry blocked: no active allocation for " + sym); return 0.0; }
   if(PositionsTotal() >= PF_MaxPositions) { PF_Log(magic, "entry blocked: position limit"); return 0.0; }

   bool ok = false;
   double riskPerLot = PF_TradeRisk(sym, type, 1.0, entry, sl, ok);
   if(!ok || riskPerLot <= 0) { PF_Log(magic, "entry blocked: cannot price the stop on " + sym); return 0.0; }
   double eq   = AccountInfoDouble(ACCOUNT_EQUITY);
   double lots = wantLots;

   lots = MathMin(lots, (eq * PF_MaxOpenRiskPct / 100.0 - PF_OpenRisk()) / riskPerLot);

   string lc, sc;
   PF_CurrencyLegs(sym, type == ORDER_TYPE_BUY ? 1 : -1, lc, sc);
   double capC = eq * PF_MaxCurrencyRiskPct / 100.0;
   lots = MathMin(lots, (capC - PF_CurrencyRisk(lc, 1)) / riskPerLot);
   if(sc != "") lots = MathMin(lots, (capC - PF_CurrencyRisk(sc, -1)) / riskPerLot);

   double marginPerLot = 0;
   if(!OrderCalcMargin(type, sym, 1.0, entry, marginPerLot) || marginPerLot <= 0)
   { PF_Log(magic, "entry blocked: cannot price margin on " + sym); return 0.0; }
   lots = MathMin(lots, (eq * PF_MaxMarginPct / 100.0 - AccountInfoDouble(ACCOUNT_MARGIN)) / marginPerLot);

   double out = PF_NormalizeLots(sym, MathMax(0.0, lots));
   if(out <= 0) PF_Log(magic, "entry skipped: portfolio limits leave no room on " + sym);
   return out;
}

//--- Volume for a new trade risking riskPct of equity (before allocation and throttle).
//    Sizing uses raw account equity, as before; only the guard uses the flow-adjusted figure.
double PF_Lots(ENUM_ORDER_TYPE type, double entry, double sl, double riskPct, long magic, string sym = "")
{
   if(sym == "") sym = _Symbol;
   if(!PF_Enabled || PF_Bypass()) return MM_CalcLots(MathAbs(entry - sl), riskPct, (ulong)magic);

   double mult = PF_RiskMult(magic, sym);
   if(mult <= 0) { PF_Log(magic, "no active allocation for " + sym + " in " + PF_AllocFile); return 0.0; }

   PF_Update(true);
   bool ok = false;
   double riskPerLot = PF_TradeRisk(sym, type, 1.0, entry, sl, ok);
   if(!ok || riskPerLot <= 0) { PF_Log(magic, "entry blocked: cannot price the stop on " + sym); return 0.0; }
   double riskMoney = AccountInfoDouble(ACCOUNT_EQUITY) * riskPct * mult * PF_ThrottleFactor() / 100.0;
   return PF_CapLots(type, entry, sl, riskMoney / riskPerLot, magic, sym);
}
