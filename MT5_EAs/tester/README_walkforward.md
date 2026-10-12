# Walk-forward pipeline

Automates Phase 2 of `../BACKTESTING_GUIDE.md` for all 15 EAs: genetic optimization on
in-sample (IS) data, a single out-of-sample (OOS) backtest per window with the chosen
parameters, and a leaderboard that ranks EAs on OOS results only.

| File | What it is |
|------|------------|
| `wf_plan.json` | Everything you tune: terminal paths, windows, deposit, tick model, per-EA parameter ranges, selection filters, pass gates |
| `wf_pipeline.py` | The pipeline (Python 3.8+, standard library only) |
| `run_pipeline.bat` | Windows wrapper: `run_pipeline.bat all` |
| `test_wf_pipeline.py` | Offline tests against synthetic MT5 reports: `python -m unittest test_wf_pipeline` |
| `optimize_IS.ini`, `run_optimization.bat` | The original one-off config, kept for manual runs |

## One-time setup

1. Copy the `MT5_EAs` folder into `<MT5 data folder>\MQL5\Experts\` and compile all EAs in
   MetaEditor (`Expert=MT5_EAs\EA1_...` in the generated configs assumes that location;
   change `expert_prefix` otherwise). Find the data folder via *File > Open Data Folder*.
2. Edit `settings` in `wf_plan.json`:
   - `terminal`: full path to `terminal64.exe`
   - `data_dir`: the MT5 data folder (reports are written to `<data_dir>\reports\wf\...`)
   - `symbols`: broker symbol names, e.g. `["EURUSD", "GBPUSD", "USDJPY", "XAUUSD"]` for the
     guide's multi-symbol test (an EA can override with its own `"symbols"`)
3. Use every core: *Tools > Options > Strategy Tester*, enable all local agents (MT5 creates one
   per logical core by default) and leave MQL5 Cloud Network off unless you want to pay for it.
4. Download history first: open each symbol's chart, or run one manual backtest per symbol with
   "Every tick based on real ticks", so the tester has real ticks for the full date range.
5. Close the terminal before running the pipeline. The tester cannot start through `/config`
   while the same terminal is already open; each job starts the terminal and `ShutdownTerminal=1`
   closes it again.

## Running

```bat
cd MT5_EAs\tester
run_pipeline.bat windows            :: print the IS/OOS windows
run_pipeline.bat generate           :: write wf_runs\is\*.ini (105 configs: 15 EAs x 7 windows x 1 symbol)
run_pipeline.bat run-is --dry-run   :: show the terminal commands without launching anything
run_pipeline.bat run-is             :: genetic optimization of every IS window (the long part)
run_pipeline.bat select             :: pick params from IS results, write wf_runs\oos\*.ini
run_pipeline.bat run-oos            :: real-tick backtest of each OOS window
run_pipeline.bat report             :: wf_runs\leaderboard.md, leaderboard.csv, windows.csv
run_pipeline.bat all                :: everything above in order
```

Add `--only EA1_MACrossover_ATR EA7_SuperTrend` to any stage to limit it to some EAs. Every
run stage skips jobs whose report already exists, so you can stop and resume; `--force` re-runs.

## What each stage does

**Windows.** Defaults: data 2016-01-01 to 2025-12-31, 4-year IS, 1-year OOS, rolled forward by
1 year, giving six walk-forward windows (OOS 2020 through 2025). A seventh window `HO` is the
guide's 70/30 holdout (IS 2016-2022, OOS 2023-2025); it is reported separately and is not
used in the walk-forward aggregate.

**IS optimization.** Genetic algorithm (`Optimization=2`), criterion 7 (complex criterion,
because none of the EAs implements `OnTester`), `Model=1` (1-minute OHLC) for speed. Only 3 to 5
strategy parameters per EA are optimized; risk settings stay fixed. Fewer free parameters is
the cheapest defence against curve fitting. EA11's grid depth and lot multiplier stay fixed on
purpose.

**Selection** uses IS data only. Passes with too few trades, a profit factor above 5 or an
equity drawdown above 30% are discarded (the guide's red flags). From the top 25 survivors the
script picks the one whose neighbourhood (every parameter within one step) has the best average
result, so a stable plateau beats a lone spike. Set `"method": "top"` to take the single best
pass instead. Choices are saved to `wf_runs\selected_params.json`.

**OOS backtest.** `Model=4` (every tick based on real ticks) with the selected parameters fixed.
IS runs on coarser ticks than OOS on purpose: any EA that only works on 1-minute OHLC
approximations is caught here rather than on live funds.

**Report.** The six OOS windows are stitched: profit factor = total gross profit / total gross
loss, drawdown = worst single-window equity drawdown, trades and win rate summed. Walk-forward
efficiency = stitched OOS PF / median IS PF. Gates (all from the guide, editable in
`pass_criteria`):

| Gate | Default |
|------|---------|
| OOS profit factor | >= 1.3 |
| OOS max equity drawdown | <= 20% |
| OOS win rate | >= 45% |
| OOS Sharpe (mean of windows) | >= 0.8 |
| Walk-forward efficiency (OOS PF / IS PF) | >= 0.6 |
| OOS trades per year | >= 50 |
| Profitable OOS windows | >= 60% |

Ranking: EAs passing every gate first, then fewest failed gates, then OOS profit factor (high),
OOS drawdown (low), OOS trade count (high). `leaderboard.md` lists passing EAs with the
parameters chosen in the most recent window, which are the ones to forward-test on demo
(Phase 4 of the guide).

The 45% win-rate gate comes from the guide; it will reject trend-following EAs with 1:3
reward/risk that are profitable at a 35% win rate. Lower it in `pass_criteria` if you agree.

## Notes and limits

- Report parsing reads the English labels of MT5 reports (`Profit Factor:`, `Total Trades:`, ...).
  Set the terminal language to English (*View > Languages*) or the columns come back empty.
- Each OOS window starts from a fresh deposit, so the stitched drawdown is the worst window,
  not a continuous equity curve.
- Runtime is dominated by `run-is`: 105 genetic optimizations. Start with `--only` on two or three
  EAs to see how long one takes on your machine.
- Generated configs are UTF-16, the encoding MT5 uses for its own ini files. If your build
  ignores them, set `"ini_encoding": "utf-8"`.
