# Backtesting & Anti-Overfitting Protocol

## Core Principle: If it only works on past data, it won't work live.

---

## Phase 1 - Initial Backtest Setup

### MT5 Strategy Tester Settings
- **Mode**: Every tick based on real ticks (highest quality)
- **Spread**: Use real/current spread, NOT fixed
- **Initial Deposit**: Match your live account size
- **Leverage**: Match your live account
- **Optimization**: Disabled for initial run

### Minimum Data Requirements
- **Minimum history**: 5 years (10 years preferred)
- **Minimum trades**: 200+ (below 200 = statistically unreliable)
- **Multiple market conditions**: Must include trending AND ranging periods

---

## Phase 2 - Walk-Forward Testing (Anti-Overfitting Core)

### Protocol
1. Split data: **70% in-sample / 30% out-of-sample**
2. Optimize ONLY on the in-sample window
3. Run out-of-sample with the SAME settings (no reoptimization)
4. Out-of-sample Profit Factor must be >= 1.3 to proceed

### Walk-Forward Windows
```
Example for 10 years data (2015-2025):
  IS1: 2015-2019  → Optimize → OOS1: 2019-2020 → Record
  IS2: 2016-2020  → Optimize → OOS2: 2020-2021 → Record
  IS3: 2017-2021  → Optimize → OOS3: 2021-2022 → Record
  IS4: 2018-2022  → Optimize → OOS4: 2022-2023 → Record
  IS5: 2019-2023  → Optimize → OOS5: 2023-2024 → Record
  
  FINAL: Average OOS performance across all windows
```

### Pass Criteria (ALL must be met)
- [ ] OOS Profit Factor > 1.3
- [ ] OOS Win Rate > 45%
- [ ] OOS Max Drawdown < 20%
- [ ] OOS Sharpe Ratio > 0.8
- [ ] Degradation ratio (OOS/IS PF) > 0.6

---

## Phase 3 - Robustness Tests

### 1. Parameter Sensitivity Test
- Vary each parameter ±20% from optimal
- If performance collapses with small changes → OVERFITTED, reject
- Performance should degrade smoothly, not cliff-drop

### 2. Multi-Symbol Test
Run on at least 4 different instruments:
- [ ] EURUSD (baseline)
- [ ] GBPUSD (correlated)
- [ ] USDJPY (different character)
- [ ] XAUUSD or USDCAD (less correlated)

Must be profitable on 3 of 4 (75%) to pass.

### 3. Multi-Timeframe Test
- Run on timeframe designed for
- Run on 1 TF above and 1 TF below
- Should not fail completely on adjacent TFs

### 4. Monte Carlo Simulation (MT5 built-in)
- Run 1000 iterations
- Maximum possible drawdown (95th percentile) < 30%
- Probability of profit > 75%

---

## Phase 4 - Forward Testing

### Mandatory Forward Test Period
- Minimum 3 months on demo account
- Full-size position sizing (not micro-lots)
- Real market conditions, real spread, real slippage

### Forward Test Pass Criteria
- Profit Factor >= 1.2 (slight degradation expected vs backtest is normal)
- Max Drawdown < 1.5x the backtest drawdown
- Trade frequency matches backtest expectations (±50%)

---

## Phase 5 - Go-Live Criteria

### Final Checklist
- [ ] Walk-forward passed all windows
- [ ] 3/4 symbols profitable
- [ ] Monte Carlo 95th percentile drawdown < 30%
- [ ] 3 months forward test passed
- [ ] Position sizing uses fixed % risk (NOT fixed lots)
- [ ] Daily loss limit implemented
- [ ] Max open trades limit implemented

### Starting Parameters
- Begin live at **50% of backtest position size**
- Scale to full size after 1 month of live results matching backtest

---

## Red Flags - Immediate Rejection

- Too-perfect equity curve (>80% straight line = suspicious)
- Profit Factor > 5.0 in backtest (unrealistic)
- Average trade > 10 pips on M1/M5 (data quality issue)
- Less than 50 trades per year
- Only profitable in one market direction
- SL never hit in backtest (look-ahead bias)
- Spread sensitivity: results collapse at 2x spread

---

## MT5 Optimization Anti-Overfitting Settings

In Strategy Tester → Optimization:
- Use **Genetic algorithm** (not full grid)
- Optimize on **Balance + max Drawdown** combined metric
- **DO NOT** optimize on: max profit alone, profit factor alone
- Use **Forward testing** = 30% of data

---

## Per-EA Testing Log Template

| EA | Symbol | TF | Period | Trades | PF | WR | DD | OOS PF | Pass? |
|----|--------|----|----|--------|----|----|-----|--------|-------|
| EA1 | EURUSD | H1 | 2015-2025 | - | - | - | - | - | - |
| EA2 | EURUSD | H1 | 2015-2025 | - | - | - | - | - | - |
...fill in as you test each EA...
