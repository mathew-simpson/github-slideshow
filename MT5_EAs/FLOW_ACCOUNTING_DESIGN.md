# Flow accounting: design note

**Status: not implemented. Blocker for live funding.** No code change until mat gives a go.
The Strategy Tester cannot test deposits or withdrawals, so this is checked on demo only.

## Problem

`PF_AdjEquity()` is `ACCOUNT_EQUITY - PF_NetFlow()`. `PF_NetFlow()` is a running sum of
balance deals (deposits and withdrawals) kept in a global variable by `PF_SyncFlows()`.
Three faults in that design:

1. **Stale flow in a non-forced update.** `PF_Update(false)` syncs at most once per second.
   A deposit raises equity at once but not `PF_NetFlow()` until the next sync, so the update
   writes an inflated peak. Example: a 1,000 account receives 300. Equity reads 1,300 with flow
   still 0, so the peak becomes 1,300. After the next sync, adjusted equity is 1,000, drawdown is
   23%, and the account halts. The inflated peak is never corrected.
2. **Deal window bounded by TimeCurrent.** The sync selects history up to `TimeCurrent()`. Deal
   times and TimeCurrent are both server time, but TimeCurrent is the last tick time, so a deal can
   fall outside the window on one sync and be read on a later one, or be counted twice.
3. **Watermark race.** Each EA advances the ticket watermark with a read-modify-write on globals
   that are not atomic across EAs. A deal that becomes visible late, below the watermark, is
   skipped for good.

## Proposed design

- **Recompute, do not accumulate.** Net flow = the sum of balance deals from a fixed baseline
   (stored per login with the baseline balance) to an open upper bound. No watermark, so no race
   and no permanently missed deal. The cost is a rescan of balance deals since the baseline,
   which is small.
- **Open upper bound.** Select history up to a far-future time, not `TimeCurrent()`.
- **Synced writes only.** Before any peak or day-start write, force a sync. If `ACCOUNT_BALANCE`
   has changed since the last sync, skip the write and sync on the next call. The one-second
   throttle applies only to the guard's log line.
- **Reconciliation check.** Balance since baseline minus net flow should equal the trade deal
   profit, commission and swap since baseline. A mismatch means a deal was missed. Log it and
   treat it as a reason to skip peak writes.
- **Open decision for mat:** should every EA write the peak (synced writes, above), or should only
   the guard write it? Recommended: synced writes from every EA, so the throttle still tracks the
   peak when the guard is not attached. The halt closing still needs the guard.

## Test plan

Demo accounts only. Never a live or competition account.

1. Deposit during a session with the guard attached. Peak, drawdown and halt stay unchanged.
2. Deposit right after a tick, within one second of the last sync. The peak must not move.
3. Withdrawal of part of the balance. Drawdown and halt stay unchanged.
4. Real loss after a deposit. Drawdown matches a hand calculation from the adjusted peak.
5. Terminal restarted while a deposit is made. The next sync records it.
6. Several EAs on one tick, and trades near midnight server time. The reconciliation check shows no mismatch.
7. Two logins on one terminal. Their keys stay separate.
8. Zero equity. Check the code path by reading it. A demo disconnect may not reproduce it.
9. Offline. Mirror the recompute and skip logic in Python under `tester/` and feed deal sequences
   with a late deal, a boundary deal and a deposit between ticks.

Live funding stays blocked until items 1 to 7 pass on demo and mat signs off on the design.
