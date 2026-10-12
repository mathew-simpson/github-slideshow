//+------------------------------------------------------------------+
//| EA00 - Portfolio Guard                                          |
//| Runs on one chart next to the strategy EAs. Does not open trades.|
//|  - keeps peak / start-of-day trading equity current between ticks|
//|    (deposits and withdrawals are not trading results)           |
//|  - at the hard-stop drawdown closes every managed position and   |
//|    halts new entries until Guard_ResetHalt is set                |
//|  - shows the portfolio dashboard and logs equity snapshots to    |
//|    Terminal\Common\Files\portfolio_equity_log.csv                |
//| Put one guard on each account's terminal. Its state is per login.|
//+------------------------------------------------------------------+
#property copyright "MT5 Trading System"
#property version   "1.00"
#include <Trade\Trade.mqh>
#include "Include/Portfolio.mqh"

// Seconds a zero equity read must last before the guard halts. The guard runs on every tick and every 5 s.
#define GUARD_ZERO_CONFIRM_SEC 10

input group "=== Portfolio Guard ==="
input double Guard_HardStopDDPct = 20.0;  // Close managed positions and halt at this drawdown from peak
input long   Guard_MagicFrom     = 10001; // Managed magic numbers, from
input long   Guard_MagicTo       = 10099; // Managed magic numbers, to
input bool   Guard_ResetHalt     = false; // One-shot: clear a halt and restart the peak. Set false and restart to re-arm.
input int    Guard_LogMinutes    = 60;    // Minutes between equity log rows (0 = off)
input string Guard_LogFile       = "portfolio_equity_log.csv";

void Guard();
void Dashboard();
void LogSnapshot();
int  CloseManaged();
bool IsManaged(long magic);

CTrade   trade;
datetime lastLog = 0;

int OnInit()
{
   // One-shot reset. The ack flag stops a restart with Guard_ResetHalt still true from
   // resetting again. Setting the input to false re-arms it on the next start.
   string ka = PF_Key(PF_GV_ACK);
   if(!Guard_ResetHalt)
      GlobalVariableSet(ka, 0);
   else if(!GlobalVariableCheck(ka) || GlobalVariableGet(ka) <= 0)
   {
      // A zero equity read must not clear the halt or store a peak. The reset stays armed for the next start.
      if(AccountInfoDouble(ACCOUNT_EQUITY) <= 0)
         Print("Portfolio Guard: reset not applied, account equity reads zero or below. The reset stays armed for the next start.");
      else
      {
         PF_SyncFlows(true);
         // Adjusted equity (equity less net flows) can read zero or below while raw equity is positive. Nothing is stored then.
         if(PF_AdjEquity() <= 0)
            Print("Portfolio Guard: reset not applied, adjusted equity reads zero or below. The reset stays armed for the next start.");
         else
         {
            GlobalVariableSet(PF_Key(PF_GV_HALT), 0);
            GlobalVariableSet(PF_Key(PF_GV_PEAK), PF_AdjEquity());
            GlobalVariableSet(ka, 1);
            Print("Portfolio Guard: halt cleared, peak trading equity reset to ", DoubleToString(PF_AdjEquity(), 2),
                  ". This reset ran once. Set Guard_ResetHalt to false and restart to re-arm it.");
         }
      }
   }
   EventSetTimer(5);
   Guard();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   Comment("");
}

void OnTick()  { Guard(); }
void OnTimer() { Guard(); }

bool IsManaged(long magic) { return magic >= Guard_MagicFrom && magic <= Guard_MagicTo; }

int CloseManaged()
{
   int left = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !IsManaged(PositionGetInteger(POSITION_MAGIC))) continue;
      if(!trade.PositionClose(t)) left++;
   }
   return left;
}

void Guard()
{
   PF_Update(true);
   // A zero or negative equity read is first logged as a read error and closes nothing. It halts
   // only if the read is still zero GUARD_ZERO_CONFIRM_SEC later, so one bad broker sample is not enough.
   static datetime zeroSince = 0;
   double raw = AccountInfoDouble(ACCOUNT_EQUITY);
   bool   zeroConfirmed = false;
   if(raw > 0)
      zeroSince = 0;
   else if(zeroSince == 0)
   {
      zeroSince = TimeLocal();
      Print("Portfolio Guard: read error, account equity read zero or below. Re-checking before any halt.");
   }
   else
      zeroConfirmed = (TimeLocal() - zeroSince >= GUARD_ZERO_CONFIRM_SEC);
   double dd = PF_DrawdownPct();
   if(!PF_Halted() && (zeroConfirmed || (raw > 0 && dd >= Guard_HardStopDDPct)))
   {
      GlobalVariableSet(PF_Key(PF_GV_HALT), 1);
      if(zeroConfirmed)
         Print("Portfolio Guard: account equity still zero or below after ", GUARD_ZERO_CONFIRM_SEC,
               " s. Closing managed positions; new entries halted until Guard_ResetHalt.");
      else
         Print("Portfolio Guard: drawdown ", DoubleToString(dd, 2), "% hit the ", DoubleToString(Guard_HardStopDDPct, 1),
               "% hard stop. Closing managed positions; new entries halted until Guard_ResetHalt.");
   }
   if(PF_Halted() && CloseManaged() > 0)
      Print("Portfolio Guard: some positions could not be closed yet (market closed?), retrying");
   Dashboard();
   LogSnapshot();
}

void Dashboard()
{
   double eq     = AccountInfoDouble(ACCOUNT_EQUITY);
   string kp     = PF_Key(PF_GV_PEAK);
   double peak   = GlobalVariableCheck(kp) ? GlobalVariableGet(kp) : PF_AdjEquity();
   double margin = AccountInfoDouble(ACCOUNT_MARGIN);
   string why    = PF_HaltReason();
   string s = "Portfolio Guard\n";
   s += StringFormat("Equity %.2f   Peak (trading) %.2f   Drawdown %.2f%%   Today %.2f%%\n", eq, peak, PF_DrawdownPct(), -PF_DayLossPct());
   s += StringFormat("Open risk %.2f%% of %.1f%% budget   Margin %.1f%%   Positions %d/%d\n",
                     eq > 0 ? PF_OpenRisk() / eq * 100 : 0, PF_MaxOpenRiskPct, eq > 0 ? margin / eq * 100 : 0,
                     PositionsTotal(), PF_MaxPositions);
   s += "New entries: " + (why == "" ? "allowed" : "BLOCKED (" + why + ")") + "\n";
   for(long m = Guard_MagicFrom; m <= Guard_MagicTo && m < Guard_MagicFrom + 100; m++)
   {
      double r = PF_OpenRisk(m);
      if(r > 0) s += StringFormat("  EA magic %d: open risk %.2f%%\n", m, eq > 0 ? r / eq * 100 : 0);
   }
   Comment(s);
}

void LogSnapshot()
{
   if(Guard_LogMinutes <= 0 || TimeCurrent() - lastLog < Guard_LogMinutes * 60) return;
   int h = FileOpen(Guard_LogFile, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON | FILE_SHARE_READ, ',');
   if(h == INVALID_HANDLE) return;
   lastLog = TimeCurrent();
   if(FileSize(h) == 0)
      FileWrite(h, "time", "login", "balance", "equity", "net_flow", "peak", "dd_pct", "open_risk_pct", "margin_pct", "positions", "blocked");
   FileSeek(h, 0, SEEK_END);
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   FileWrite(h, TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES),
             IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)),
             DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2), DoubleToString(eq, 2),
             DoubleToString(PF_NetFlow(), 2),
             DoubleToString(GlobalVariableGet(PF_Key(PF_GV_PEAK)), 2), DoubleToString(PF_DrawdownPct(), 2),
             DoubleToString(eq > 0 ? PF_OpenRisk() / eq * 100 : 0, 2),
             DoubleToString(eq > 0 ? AccountInfoDouble(ACCOUNT_MARGIN) / eq * 100 : 0, 2),
             PositionsTotal(), PF_HaltReason());
   FileClose(h);
}
