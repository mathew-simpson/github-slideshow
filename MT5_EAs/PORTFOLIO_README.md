# Portfolio money management

Capital is split across the EAs by a portfolio layer, not by each EA alone. Nothing here
changes live trading until you copy the allocation file to the terminal and attach the guard.

| File | What it does |
|------|--------------|
| `Include/Portfolio.mqh` | Shared allocator. Every EA sizes through `PF_Lots()`. Applies the EA's allocation multiplier, a drawdown throttle, and account-wide caps. |
| `EA00_PortfolioGuard.mq5` | Watcher on one chart. Tracks peak equity, closes managed positions and halts new entries at the hard-stop drawdown, shows a dashboard, logs equity to CSV. |
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
| `PF_ThrottleDDPct` / `PF_HaltDDPct` | 8 / 15 | Trade size shrinks linearly from 8% drawdown (down to 25%) and new entries stop at 15%. |
| `PF_DailyLossPct` | 4 | Account loss today that stops new entries. |

A trade is skipped, never rounded up, when the allowed volume is below the broker minimum.

## Strategy Tester behaviour

Tester runs size exactly as before this change, so walk-forward results stay comparable and
do not depend on terminal state. `PF_UseAllocInTester = true` turns the allocator on in the
tester, but that only checks the sizing logic. Portfolio effects still need a combined
simulation, which the pipeline does not do yet.

## Setup

1. Run the walk-forward pipeline (`run_pipeline.bat report`) so `wf_runs\leaderboard.csv` exists.
2. `python portfolio_alloc.py` (from `MT5_EAs\tester`). Optional flags: `--max-mult`,
   `--min-trades-per-year`, `--require-holdout-pf 1.0`.
3. Copy `wf_runs\portfolio_allocation.csv` to `<terminal data folder>\Common\Files\portfolio_allocation.csv`.
4. Compile all EAs and `EA00_PortfolioGuard.mq5` in MetaEditor. Attach the guard to any chart on
   the account. Keep it running; the hard stop works only while it runs.
5. Demo first. Check the Experts log for `PF: loaded N allocation rows` and the guard dashboard.

To halt everything, set the guard input `Guard_ResetHalt` only to clear a halt. To stop
trading manually, remove the allocation file or set every row to `inactive`.

## Known gaps

- Correlation between EAs is handled only by the currency-exposure cap. Measuring it properly
  needs daily OOS return series per EA, which the pipeline does not export yet.
- The allocator scores EAs on OOS profit factor and drawdown only. It does not use IS data.
- Nothing has been compiled in MetaEditor from this environment; run the compile on the
  Windows machine before use.
