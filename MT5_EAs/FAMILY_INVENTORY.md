# EA family inventory

Classifies the 15 trading EAs by strategy family and order type, and records what evidence exists for each.
Source: `MT5_EAs/EA*.mq5` on this branch (stacked on the portfolio PR). Nothing here was compiled or backtested
in this environment; the evidence column comes from result files on the owner's Windows machine.

## Order types

Every trading EA places orders with `CTrade` market orders only (`trade.Buy` / `trade.Sell`, SL and TP attached
at entry). No EA uses pending orders (buy/sell limit, buy/sell stop). EA11 adds more market orders at grid
levels, so it is a grid by spacing, not by pending order.

So the "order-type families" today are one family: **market, SL/TP-bracketed**. Limit and stop variants do not
exist yet and would be new EAs or new modes, not improvements to existing ones.

## Strategy families

| Family | EAs | Entry idea | Notes |
|--------|-----|------------|-------|
| Trend following | EA1 MA crossover, EA4 MACD momentum, EA5 Ichimoku, EA7 SuperTrend, EA10 three MAs, EA13 ADX directional move | Moving-average, MACD, cloud or band direction, with an ADX or trend filter | Low win rate by design; the 45% win-rate gate in `wf_plan.json` rejects 1:3 designs |
| Mean reversion | EA2 RSI, EA6 stochastic swing, EA14 CCI divergence | Oscillator extremes, with a higher-timeframe or trend filter | |
| Breakout and volatility | EA3 Bollinger squeeze, EA9 ATR channel, EA15 Asian-range breakout | Range or band break, often session-gated | EA15 fixes the session by hour inputs |
| Price action | EA8 pin bar | Candle shape at an EMA-200 filter | |
| Scalping | EA12 scalping momentum | Fast EMA cross with RSI bias, `MaxBarsHeld` time exit | Small risk (0.5%), sensitive to spread |
| Grid recovery | EA11 grid recovery | Trend entry, then market-order grid on adverse moves with lot multiplier 1.5 | Martingale-like. Grid depth and multiplier are deliberately fixed in the walk-forward run. Highest risk of ruin in the set |
| Portfolio guard | EA00 | Not a trader. Equity halt and allocation across the others | See `PORTFOLIO_README.md` |

## Evidence on hand

- The walk-forward pipeline (`tester/wf_pipeline.py`) has not produced a leaderboard on the owner's machine.
  No `wf_runs/leaderboard.csv` was found, so no EA has passed the gates.
- One result file covers EA5 Ichimoku (`results_recent_20261010_220104.csv`, EURUSD H1): in-sample PF 1.05, out-of-sample PF 1.23, 53 OOS trades.
  Out-of-sample is better than in-sample on a short window, which is a warning sign, not a pass. It is a single symbol and one split.
- Direction and regime studies (`drc_*`, `f7_*` on the owner's machine) show mostly negative net per trade after costs.
  They study bar-level direction, not the EAs, so they do not clear any EA.

## Next steps (not done here)

1. Run `run_pipeline.bat run-is --only <family>` per family on the owner's machine, then `select`, `run-oos`, `report`.
2. Promote only EAs that pass every gate on out-of-sample data. Do not tune on the holdout window.
3. Pending-order variants are not started. Add them only if a family's market-order version passes and the
   entry-timing loss is measured.

## Both sides of each open choice

Where a defect fix changes which trades happen, the default keeps the legacy behaviour and a switch turns the
new behaviour on. The walk-forward pipeline can then run both sides on the same data without a code change.
Defaults are unchanged, so existing results still mean what they meant.

| EA | Switch | Default (legacy) | Other side | Trade-off |
|----|--------|------------------|------------|-----------|
| EA3 | `UseSqueezeFilter` | off: breakouts unfiltered, squeeze inputs unused | on: breakout only after `SquezeBars` bars of narrow bands | Fewer, cleaner breakouts vs. the trade count gate (>= 50 OOS trades/yr) |
| EA15 | `ServerGMTOffset` | 0: session hours are broker server hours (legacy) | broker's UTC offset, e.g. 2 or 3: session hours follow GMT | Breakout timing vs. the London open; set it to the broker's offset for the period tested, since DST shifts it |
| EA15 | `OneTradePerDay` | off: a stop-out can be followed by a new breakout the same day (legacy) | on: one breakout trade per day | Fewer trades and less re-entry risk vs. losing the second chance on a trend day |
| EA11 | `UseEquityStops` | off: daily and grid stops use realized balance | on: equity, so open grid losses trigger the stops | Earlier cut-off on bad grids vs. more forced exits in a normal drawdown |

To test a side, set it in `wf_plan.json` under that EA's `"fixed"` block, using JSON `true` or `false`, e.g.
`"fixed": {"UseSqueezeFilter": true}`, then run the pipeline into a separate report folder for each side and compare
the leaderboards. Do not pick the side from the holdout window.

EA15 also has three bug fixes that are not switches, because they only change what the input says:
`AsianEndH` now binds (the range is built at the close of the Asian window, so the default range is 00:00-07:00
instead of 00:00-06:00); the M1 bar scan no longer stops at 299 bars; and `MinRangePips` uses a real pip size
on 2- and 4-digit symbols.

Not switched, and why:

- **EA5 Chikou:** the correct buffer convention depends on the MT5 build. Verify it against the terminal before changing it.
- **EA14 divergence:** not implemented. Implementing it would be a new strategy, not a fix. Build it as its own EA
  only if the CCI re-cross version is worth extending.
- **EA1 trailing stop:** tightens to 1 ATR from the first tick. Whether that is wanted is a design choice; the
  walk-forward run will show whether it hurts.
