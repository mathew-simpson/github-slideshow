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
