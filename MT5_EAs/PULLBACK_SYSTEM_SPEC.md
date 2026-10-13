# System 2: EURUSD pullback capture (pre-registered spec)

Version 1.0, registered 2026-10-13, before any backtest of this EA was run.
Implementation: `EA16_PullbackCapture.mq5` (magic 10016). Tester configs: `tester/pullback_IS.ini`
(the in-sample grid) and `tester/pullback_OOS.ini` (the single out-of-sample run).

This file is written before the first backtest on purpose. Everything a test can be tuned
on (rules, parameters, ranges, windows, pass gates) is fixed here. Results may only be
compared against this file; anything changed after the out-of-sample run is a new version
(see "Change control").

## 1. What the system is for

The project runs two systems on EURUSD:

| | System 1: trend hold | System 2: pullback capture (this spec) |
|---|---|---|
| Direction | With the D1 trend | Against the D1 trend, inside it |
| Holding time | Several days | Hours, at most `MaxHoldBars` H1 bars |
| Makes money when | The trend extends | The trend pauses and retraces |
| Gives back when | The trend pulls back | The trend resumes early |

System 2 trades the retracement that System 1 sits through. It never trades against a
missing trend: no D1 trend, no trade. The two are meant to be partly offsetting, which
is the point of running them together; System 2 is judged on its own results first.

**Account requirement:** a hedging account. On a netting account a System 2 sell would
reduce System 1's long instead of opening a separate position.

## 2. Rules

All signals use closed bars only (shift 1 and older). Execution timeframe H1, trend
timeframe D1. Long rules in a D1 downtrend are the exact mirror of the short rules below.

### 2.1 D1 trend filter (uptrend shown)

All three on the last closed D1 bar:
1. D1 close > D1 EMA(`D1_TrendMA`)
2. D1 EMA(`D1_TrendMA`) now > the same EMA `D1_SlopeBars` days earlier
3. D1 ADX(14) >= `D1_MinADX`

### 2.2 Impulse leg

On H1, over the last `ImpulseLookback` closed bars:
- `legHigh` = highest high, which must have printed within the last `FreshBars` bars
  (the up-leg is still fresh, not a stale top)
- `legLow` = lowest low of the bars before `legHigh` in that same lookback
- leg size `legHigh - legLow` must be at least `MinLegATR` x H1 ATR(14)

### 2.3 Counter-trend entry (pullback start)

Sell at market on the open of the next bar when the last closed H1 bar is the first close
below H1 EMA(`H1_FastMA`) after closing above it, and the impulse leg above is valid.
One trade per impulse leg: no new entry while `legHigh` is the same extreme the last
trade was taken from.

### 2.4 Exits (pullback end)

Whichever comes first:
- **Target:** `legHigh - TargetRetrace x leg size`, set as the take-profit.
- **Resumption:** an H1 close back above EMA(`H1_FastMA`), checked from the second bar
  after entry. The pullback is over; close at market.
- **Stop:** `legHigh + SL_ATR_Buffer x ATR`, set as the stop-loss. A new high means the
  pullback did not happen.
- **Time:** `MaxHoldBars` H1 bars after entry.
- **Trend gone:** the D1 filter no longer holds for the trend the trade was taken against.

A setup whose target is closer than `MinRR` x the stop distance is skipped.

### 2.5 Spread budget

Both must hold at entry, or the bar is skipped:
- current spread <= `MaxSpreadPoints` (default 20 points = 2.0 pips on a 5-digit quote)
- current spread <= `MaxSpreadFrac` x the distance to the target (default 0.10), so the
  spread never eats more than a tenth of the planned gain

Entries are also limited to server hours `StartHour` to `EndHour`, which keeps the
rollover-hour spread spike out.

### 2.6 Risk per trade

- `RiskPercent` = 0.5% of balance at the stop, sized through `PF_Lots` in
  `Include/Portfolio.mqh` (which uses `Include/MM_Common.mqh`). The portfolio caps
  (open risk, currency risk, drawdown throttle, daily loss) apply as for every other EA.
- One System 2 position at a time.
- System 2 risk is half of a typical System 1 trade (1%) because it is the
  counter-trend leg and its expected win size is smaller.

## 3. Parameters

Only four parameters are optimised. Everything else is fixed at its default and may not
be tuned in this version.

| Input | Default | Optimised range (start, step, stop) | Why it exists |
|---|---|---|---|
| `H1_FastMA` | 20 | 10, 5, 30 | Defines pullback start and end |
| `TargetRetrace` | 0.5 | 0.3, 0.1, 0.7 | How much of the leg the pullback is expected to give back |
| `SL_ATR_Buffer` | 0.5 | 0.25, 0.25, 1.0 | Room above the leg extreme |
| `MaxHoldBars` | 24 | 12, 6, 48 | Time stop |
| `D1_TrendMA` | 50 | fixed | |
| `D1_SlopeBars` | 5 | fixed | |
| `D1_MinADX` | 20 | fixed | |
| `ImpulseLookback` | 48 | fixed | |
| `FreshBars` | 12 | fixed | |
| `MinLegATR` | 3.0 | fixed | |
| `MinRR` | 1.0 | fixed | |
| `MaxSpreadPoints` | 20 | fixed | |
| `MaxSpreadFrac` | 0.10 | fixed | |
| `RiskPercent` | 0.5 | fixed | |
| `StartHour` / `EndHour` | 7 / 20 | fixed | |

Grid size: 5 x 5 x 4 x 7 = 700 combinations, small enough for a full (slow complete)
search, so the genetic optimiser's randomness is not a source of selection bias.

## 4. Data windows

| Window | Dates | Use | Tick model |
|---|---|---|---|
| In-sample (IS) | 2015-01-01 to 2022-12-31 | Optimisation and parameter choice | 1-minute OHLC (`Model=1`) |
| Out-of-sample (OOS) | 2023-01-01 to 2025-12-31 | One confirmation run with the chosen parameters | Every tick based on real ticks (`Model=4`) |
| Forward | From go-live on demo | At least 3 months or 40 trades on a demo account | Live |

The OOS window is run **once** per spec version. Data after 2025-12-31 is not used for
anything until the forward test, so it stays clean for that.

## 5. Selection (IS only)

1. Run the full grid on IS.
2. Discard any pass with fewer than 40 trades per year, a profit factor above 3.0, or an
   equity drawdown above 20%.
3. Among the rest, take the pass whose neighbourhood (every optimised input within one
   step) has the best median profit factor. A lone spike surrounded by losers is rejected
   even if it is the top pass.
4. The neighbourhood's worst profit factor must be >= 1.0. If no pass meets that, the
   system fails IS and OOS is not run.
5. Record the chosen parameters in this file (section 8) before the OOS run.

## 6. Pass gates (OOS)

All must hold on the single OOS run:

| Gate | Threshold |
|---|---|
| Trades | >= 100 over the three years |
| Profit factor | >= 1.25 |
| Equity drawdown | <= 15% |
| Walk-forward efficiency (OOS PF / IS PF of the chosen pass) | >= 0.6 |
| Profitable calendar years | >= 2 of 3 |
| Cost stress: OOS trades recomputed with an extra 0.5 pip cost each (about +50% of a typical EURUSD spread) | PF >= 1.1 |

Then the forward demo test must be profitable with no single loss above 1.5x planned risk
before any live funds.

## 7. Anti-overfitting rules

1. **This file is the registration.** Its git commit is the timestamp. Rules, ranges,
   windows and gates may not change after the first IS run without a new version.
2. **At most four optimised inputs**, all with economic meaning. Risk, spread and session
   inputs are never optimised.
3. **Full grid, not best-of-several genetic runs.** One run, one result set, all passes kept.
4. **Plateau selection** (section 5), never the single top pass.
5. **OOS runs once.** Looking at OOS and then changing anything (rules, ranges, selection
   filters) burns the window: the next version must state that it saw OOS v1 and must
   be judged on the forward test, not on 2023-2025.
6. **Count every trial.** Each spec version, each IS grid and each OOS run is logged in
   section 8, including failures. A system that only passes on the fifth try is weaker
   evidence than one that passes on the first, and the log keeps that visible.
7. **Real ticks for OOS** and a cost stress check, so an edge that only exists on smoothed
   1-minute bars or tight spreads is caught before live.
8. **No peeking at dates after 2025-12-31** before the forward test.

## 8. Trial log

| Date | Version | Run | Result | Notes |
|---|---|---|---|---|
| 2026-10-13 | 1.0 | Spec registered, EA written | Not run | Backtests run on the user's PC |

## Change control

A change to section 2, 3, 4, 5 or 6 bumps the version (1.0 to 1.1 for a fix that does
not change behaviour on any bar, 2.0 otherwise), adds a trial-log row, and is committed
before any new run.
