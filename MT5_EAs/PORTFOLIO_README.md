# Portfolio money management

Capital is split across the EAs by a portfolio layer, not by each EA alone.

Be aware of two things before compiling:
- Recompiled EAs keep `PF_RequireAlloc = true` by default. Without `portfolio_allocation.csv` in
  `Common\Files`, no EA opens a live trade. That is the safe default.
- The hard stop works only while `EA00_PortfolioGuard` runs on the account's terminal.

| File | What it does |
|------|--------------|
| `Include/Portfolio.mqh` | Shared allocator. Every EA sizes through `PF_Lots()`. Applies the EA's allocation multiplier, a drawdown throttle, and account-wide caps. |
| `EA00_PortfolioGuard.mq5` | Watcher on one chart. Tracks peak trading equity, closes managed positions and halts new entries at the hard-stop drawdown, shows a dashboard, logs equity to CSV. |
| `tester/portfolio_alloc.py` | Turns `wf_runs/leaderboard.csv` into `portfolio_allocation.csv`. Only EAs that pass every walk-forward gate get capital. |
| `tester/test_portfolio_alloc.py` | Offline tests for the allocator. |

"Every dollar working" means capital spread across several strategies, sessions and symbols
with caps on total risk. It does not mean more leverage.

## What the allocator enforces (live and demo only)

| Input | Default | Meaning |
|-------|---------|---------|
| `PF_RequireAlloc` | true | An EA with no active row in the allocation file does not trade. |
| `PF_MaxOpenRiskPct` | 6 | Total money at risk to stop-losses across all EAs, % of equity. |
| `PF_MaxCurrencyRiskPct` | 3 | Risk long or short any one currency, % of equity. |
| `PF_MaxPositions` | 12 | Open positions on the account. |
| `PF_MaxMarginPct` | 30 | Margin in use, % of equity. |
| `PF_ThrottleDDPct` / `PF_HaltDDPct` | 8 / 15 | Trade size shrinks linearly from 8% drawdown (down to 25%) and new entries stop at 15%. Grid adds in EA11 are throttled the same way. |
| `PF_DailyLossPct` | 4 | Account loss today that stops new entries. |

A trade is skipped, never rounded up, when the allowed volume is below the broker minimum.

A trade is also skipped, not sized from a guess, when:
- it has no stop loss, or the broker cannot price the stop distance;
- the broker cannot price the margin for the symbol;
- the EA has no active row in the allocation file (with `PF_RequireAlloc` true).

An open position with no stop, or one that cannot be priced, is counted at `PF_NoSLRiskPct`
(2% of equity) toward the open-risk caps. That is only for accounting, never for sizing.

## Deposits, withdrawals and accounts

- Deposits and withdrawals do not count as trading losses. The guard subtracts the net balance
  operations from equity before it measures drawdown and the daily loss. A $20 withdrawal from
  a $100 account does not trigger the hard stop.
- Fees, commissions and swaps stay in equity, so they still count as losses.
- Every global variable key includes the account login. Two accounts on one terminal keep
  separate peaks, day starts and halts.
- The first run for a login starts a baseline at the current account history. Deposits and
  withdrawals made before that baseline are not counted. This also means a halt from an older
  build (keys without a login) is not inherited. Check that no position is open after an upgrade.
- Sizing and the caps still use raw account equity, as before. Only the guard uses the adjusted figure.

## Strategy Tester behaviour

Tester runs size exactly as before this change, so walk-forward results stay comparable and
do not depend on terminal state. `PF_UseAllocInTester = true` turns the allocator on in the
tester, but that only checks the sizing logic. Portfolio effects still need a combined
simulation, which the pipeline does not do yet.

In the tester, a volume below the broker minimum is rounded up to the minimum, as the original
EAs did. Live, the same trade is skipped. Backtests on small accounts therefore risk more than
the live account would.

## Setup

1. Run the walk-forward pipeline (`run_pipeline.bat report`) so `wf_runs\leaderboard.csv` exists.
2. `python portfolio_alloc.py` (from `MT5_EAs\tester`). Optional flags: `--max-mult`,
   `--min-trades-per-year`, `--require-holdout-pf 1.0`.
3. Copy `wf_runs\portfolio_allocation.csv` to `<terminal data folder>\Common\Files\portfolio_allocation.csv`.
4. Compile all EAs and `EA00_PortfolioGuard.mq5` in MetaEditor. Attach the guard to one chart on
   each account's terminal. Keep it running; the hard stop works only while it runs.
5. Demo first. Check the Experts log for `PF: loaded N allocation rows` and the guard dashboard.

## Halts, resets and stopping

- **Halt:** the guard sets it at the hard-stop drawdown and closes managed positions. It stays
  set until reset.
- **Reset:** set `Guard_ResetHalt` to true, let the guard start, then set it back to false. The
  peak restarts at the current trading equity. Do this only after reviewing why the halt fired.
- **Stop new entries without a halt:** remove `portfolio_allocation.csv` from `Common\Files`
  (with `PF_RequireAlloc` true) or set every row to `inactive`. The EAs re-read the file at
  most once a minute.
- **Stop everything:** detach the EAs from their charts.
- Do not set `PF_RequireAlloc` to false on a live account unless you have decided to trade
  without an allocation.

## Known gaps

- **Small accounts.** On a $100 account, a 0.01 lot minimum risks about 1 currency unit per
  10 pips on EURUSD. A 20-pip stop therefore risks 2% of equity even at 1% RiskPercent, and the
  live allocator skips the trade. Check the broker's real minimum lot and leverage before
  going live on a small account. At 1:30, the 0.01 lot margin is above the 30% margin cap.
- **Sizing base.** Sizing uses equity, not balance. The tester and the original EAs used balance.
- **Correlation.** Correlation between EAs is handled only by the currency-exposure cap.
  Measuring it properly needs daily OOS return series per EA, which the pipeline does not export yet.
- **Concurrency.** Two EAs can check the caps at the same moment and each pass the same headroom,
  so the caps can be overshot by one entry.
- **Index CFDs** are not counted against any currency cap; only the per-symbol exposure applies.
- **Timeframe.** The allocation file has no timeframe column, so an EA on a chart of another
  timeframe still gets capital.
- **PF_Enabled = false** disables the halt and the caps along with the allocator. Do not use it live.
- **Guard_ResetHalt** is not one-shot. If it stays true, every restart of the guard clears a halt.
- The allocator scores EAs on OOS profit factor and drawdown only. It does not use IS data.
- Nothing has been compiled in MetaEditor from this environment; run the compile on the
  Windows machine before use.
