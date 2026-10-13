# EA improvement loop

A recurring cycle that tries one small change per EA, backtests it, keeps it only when it holds up out of
sample, and writes down what it learned so the next cycle starts from there. The runbook for one cycle is
[`CYCLE.md`](CYCLE.md); the record of every change tried is [`CHANGELOG.md`](CHANGELOG.md).

## What one cycle does

1. Reads the latest backtest sweep from the MT5 PC (or the EA defaults on the first run).
2. Proposes one change per EA: a one-step parameter move, or, after three failed moves in a row, a logic
   idea behind a new on/off input.
3. Backtests the EA's current settings and the change on three windows on the PC: in-sample
   2015-2022, out-of-sample 2023-2025 and a holdout January to September 2026.
4. Keeps the change only if out-of-sample results improve without hurting in-sample quality, trade count or
   drawdown, and the holdout does not get worse.
5. Logs every attempt, kept or dropped, to `changelog.jsonl`, updates `state.json` and `sets/<EA>.set`, and
   pushes the result to a draft PR. Nothing merges, trades or touches the terminal login without the owner.

## Files

| File | What it is |
|------|------------|
| `loop.py` | The loop: `init`, `propose`, `run`, `ingest`, `evaluate`, `status` (Python 3.8+, standard library) |
| `loop_config.json` | Tester settings, windows, acceptance gates, EA families, frozen inputs |
| `loop_config.local.json` | PC-only overrides (terminal path, data folder); gitignored |
| `search_space.json` | Per-EA parameter ranges, copied from `../tester/wf_plan.json`, which wins once merged |
| `logic_ideas.json` | Logic changes the loop may try, by family |
| `state.json` | Each EA's current settings and their baseline results |
| `changelog.jsonl` / `CHANGELOG.md` | Every change tried, with metrics and the reason it was kept or dropped |
| `cycles/NNN/` | One cycle: `proposals.json`, tester `.ini` files, `results.json`, `SUMMARY.md`, logic `patches/` |
| `sets/<EA>.set` | Tester/chart presets with the kept settings |
| `test_loop.py` | Offline tests: `python -m unittest test_loop` |

## Running by hand

```bat
cd MT5_EAs\improve
python loop.py init --sweep path\to\sweep.csv --ea-dir ..
python loop.py propose                 :: or --only EA1_MACrossover_ATR EA7_SuperTrend
python loop.py run --dry-run           :: show terminal commands; drop --dry-run on the MT5 PC
python loop.py ingest
python loop.py evaluate
python loop.py status
```

The sweep CSV needs an `ea` (or `expert`/`name`) column; an optional `params` column (`A=1;B=2` or JSON)
seeds the current settings, and `rank` is kept for reference.

## Guarding against fooling ourselves

- One change at a time per EA, so each result says something about that change.
- Decisions use OOS results, but a change that buys OOS profit by losing IS quality is dropped.
- The holdout is only looked at after the OOS gates pass, and it can only veto.
- Each EA gets 40 tries per OOS window. Past that the windows must be rolled forward, because enough
  attempts against one window will find something that fits it by chance.
- Reports parse the English labels of MT5 reports; keep the terminal language English.

## Lessons

Cycles add a line here when a pattern shows up across the changelog.

- None yet.
