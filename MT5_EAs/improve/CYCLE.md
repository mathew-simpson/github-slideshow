# Improvement cycle runbook

The recurring trigger wakes the project's loop thread with "run the next EA improvement cycle". That
session follows these steps. The MT5 terminal and Strategy Tester live on the owner's PC, so the backtest
step is handed to a session on that PC; everything else runs in the cloud checkout.

## Hard limits (every step)

- Nothing merges. Every cycle lands as commits on the loop branch behind a draft PR for the owner to review.
- No live or demo orders are placed, changed or closed. Only the Strategy Tester runs.
- The terminal login is never changed. If the tester needs a different account, stop and ask the owner.
- Backtests only run on a terminal logged into a demo login listed in `tester.allowed_logins`, in hedging
  mode. `loop.py run` reads the terminal journal and refuses otherwise, so a real-money terminal is never
  used. Never add a real account to that list. Do not use `D:\MT5_EA` (logged into a real account) unless
  the owner says it has been moved to a demo login and locked down.
- Never edit files owned by another open thread or PR (the sweep, agent-repair and walk-forward work).
  The loop writes only inside `MT5_EAs/improve/`. A logic change to an `.mq5` is tested on the PC and comes
  back as a patch file under `cycles/NNN/patches/`, not as an edit to the EA in the repo.
- Never tune on the holdout window. It is only checked for changes that already passed the OOS gates.

## Steps

1. **Check for an open cycle.** `python loop.py status`. If a cycle is open and its results have not come
   back from the PC, do not start another one: check on the PC session, refresh the thread status, stop.

2. **Read the latest sweep.** Ask the PC session for the newest summary CSV under
   `MT5_EAs\tools\sweep\` (written by the sweep thread). On the first cycle, or when `state.json` is
   missing, seed it: save the CSV as `cycles/sweep_latest.csv` and run
   `python loop.py init --sweep cycles/sweep_latest.csv --ea-dir <folder with the .mq5 files>`.
   No sweep yet: seed from the `.mq5` defaults alone (`init` without `--sweep`) and say so in the reply.

3. **Propose.** `python loop.py propose`. One change per EA:
   - A parameter moves one step (from `search_space.json`, or `../tester/wf_plan.json` once merged) in the
     direction with the best track record. Moves already tried from the same settings, values rejected
     twice, and steps back to a value a kept change replaced are skipped.
   - After three dropped changes in a row for an EA, the next proposal is a logic change from
     `logic_ideas.json`, added behind a new input flag that defaults to `false`. The PC session adds that
     flag to the EA, compiles it, and returns the diff.
   - EA11's grid depth, lot multiplier and risk inputs are frozen and never proposed.
   - An EA that has used its OOS budget (40 tries) is skipped until the windows are rolled forward,
     because repeated testing against one OOS window slowly fits to it.
   Commit `state.json` and `cycles/NNN/` (proposals and `.ini` files) and push, so the PC can pull them.

4. **Backtest on the PC.** Brief the PC session (Remote Control in this thread; reuse it if one is
   running) with the block below, filled in with the cycle number. Then end the turn and wait for its
   message.

   > Refresh `C:\Users\bradb\OneDrive\Desktop\claude\loop_repo` from branch `<loop branch>` of
   > mathew-simpson/github-slideshow (the PC has no git: download the branch zip and copy `MT5_EAs\improve`
   > over, keeping `loop_config.local.json` and `cycles\*\reports`). Use the tester terminal named in
   > `loop_config.local.json` (`tester.terminal`, `tester.data_dir`, `tester.portable`). **Before running,
   > confirm that terminal is logged into a hedging account; if it is netting, stop and report, do not run.** For each `logic` proposal in
   > `cycles\NNN\proposals.json`, add the described behaviour to that EA in the terminal's
   > `MQL5\Experts\MT5_EAs` folder behind the named `input bool` flag defaulting to `false`, compile it, and
   > keep the diff. Then run `python loop.py run --cycle NNN` and `python loop.py ingest --cycle NNN`.
   > Close the terminal first if the tester cannot start through `/config`. Do not change the terminal
   > login and do not place, change or close any order. Send back the contents of
   > `cycles\NNN\results.json`, every logic diff, and any job that produced no report and why.

5. **Evaluate.** Write the returned JSON to `cycles/NNN/results.json` and the diffs to
   `cycles/NNN/patches/<EA>.diff`, then `python loop.py evaluate`. A change is kept only if, against the
   EA's current settings:
   - OOS profit factor rises at least 3%, with at least 30 OOS trades,
   - OOS relative equity drawdown worsens by no more than 10% (plus half a point),
   - IS profit factor keeps at least 95% of its value and stays at or below 5 (a curve-fit flag),
   - IS and OOS trade counts each keep at least 70%,
   - and then the holdout profit factor keeps at least 95%.
   Missing reports are "not judged" and the change is retried next cycle. Thresholds live in
   `loop_config.json` under `acceptance`.

6. **Record and publish.** `evaluate` appends every result to `changelog.jsonl`, regenerates
   `CHANGELOG.md`, writes `cycles/NNN/SUMMARY.md`, and writes `sets/<EA>.set` for EAs whose change was
   kept. Run `python -m unittest test_loop`, commit, push, and make sure a draft PR is open for the loop
   branch (open a new one if the previous loop PR was merged, restarting the branch from master first).
   Reply in the thread with what was kept and dropped, linking the PR and the cycle summary.

7. **Learn.** Look across `CHANGELOG.md`. If one kind of change keeps failing for a family (for example
   every stop-loss widening on trend EAs), add a line to the "Lessons" section of `README.md` and, where it
   generalises, narrow the search space or the idea list in the same commit. This is how the process itself
   improves, not just the EAs.
