# Cycle 001: run on a netting account, not scored

All 90 jobs ran on 2026-10-13 on the portable terminal at `D:\MT5_EA`, but that terminal is logged into
Trading.com 100149667, a netting account. `evaluate` was **not** run, so nothing from this run is in the
changelog. The cycle stays open and is re-run with `python loop.py run --force` once the tester has a
hedging login.

- EA1, EA10 and EA12 hit a margin stop-out in all six jobs: their position cap counts positions, which is
  always 1 on netting, so they kept adding to it. Their numbers are meaningless.
- The other 12 ran their full windows, but on netting, so they may differ from a hedging run.
- Two EA11 jobs were aborted when another agent switched the terminal's account mid-run; they were re-run.

Unscored first look (profit factor / trades, IS | OOS | holdout). Not one EA clears PF 1.0 out of sample
by a useful margin on these settings:

| EA | baseline | candidate |
|----|----------|-----------|
| EA2 RSI | 0.78/93, 0.80/36, 0.97/7 | 0.58/48, 0.58/13, 1.32/4 |
| EA3 Bollinger | 0.91/1562, 0.88/653, 0.65/169 | 0.92/1559, 0.90/646, 0.69/165 |
| EA4 MACD | 0.68/318, 0.86/113, 0.42/25 | 0.68/303, 0.93/108, 0.36/22 |
| EA5 Ichimoku | 0.91/473, 0.99/200, 0.81/41 | 0.89/480, 1.00/195, 0.76/42 |
| EA6 Stochastic | 0.66/497, 1.04/192, 0.59/60 | 0.66/483, 1.04/196, 0.57/61 |
| EA7 SuperTrend | 0.90/1535, 1.03/596, 0.73/140 | 0.89/1547, 1.03/596, 0.82/139 |
| EA8 Pin bar | 0.74/1020, 0.94/434, 1.20/113 | 0.73/1050, 0.95/446, 1.17/118 |
| EA9 ATR channel | 0.83/869, 0.88/351, 0.76/83 | 0.86/791, 0.88/308, 0.73/77 |
| EA11 Grid | 0.90/2091, 0.93/843, 0.96/180 | 0.92/2090, 0.93/844, 1.03/187 |
| EA13 ADX | 1.21/88, 0.97/43, 0.21/8 | 0.88/37, 0.87/16, 0.00/3 |
| EA14 CCI | 0.82/889, 0.95/362, 0.90/87 | 0.81/828, 0.99/350, 0.91/68 |
| EA15 Morning breakout | 0.75/2657, 0.73/1104, 0.66/262 | 0.73/2876, 0.72/1187, 0.65/290 |
