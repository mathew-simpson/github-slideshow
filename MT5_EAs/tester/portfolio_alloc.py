"""Turn the walk-forward leaderboard into the allocation file read by Include/Portfolio.mqh.

Only EAs whose leaderboard row passes every gate get capital. Among those, each EA's
risk multiplier is proportional to its OOS profit factor (capped) divided by its OOS
max drawdown, then scaled so the average active multiplier is 1.0. Each EA's own
RiskPercent input is multiplied by that value, and the EA guard enforces the
account-wide limits on top.

Usage (from MT5_EAs\\tester):
    python portfolio_alloc.py                          # wf_runs\\leaderboard.csv -> wf_runs\\portfolio_allocation.csv
    python portfolio_alloc.py --leaderboard X.csv --out Y.csv --max-mult 2.0

Copy the output to <terminal data folder>\\Common\\Files\\portfolio_allocation.csv
(the path Include/Portfolio.mqh reads with FILE_COMMON).

Standard library only. Python 3.8+.
"""

import argparse
import csv
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SOURCE_DIR = HERE.parent          # MT5_EAs
MAGIC_RE = re.compile(r"SetExpertMagicNumber\(\s*(\d+)\s*\)")
HEADER = ["ea", "magic", "symbol", "risk_mult", "weight", "status", "reason"]


def read_magics(source_dir):
    """Map EA file stem (e.g. EA1_MACrossover_ATR) to its magic number, from the source."""
    magics = {}
    for path in sorted(Path(source_dir).glob("EA*.mq5")):
        if path.stem.startswith("EA00"):
            continue  # the guard has no magic and opens no trades
        m = MAGIC_RE.search(path.read_text(encoding="utf-8", errors="replace"))
        if not m:
            raise ValueError(f"{path.name}: no SetExpertMagicNumber(...) found")
        magics[path.stem] = int(m.group(1))
    return magics


def _num(text):
    try:
        return float(text)
    except (TypeError, ValueError):
        return None


def _flag(text):
    return str(text).strip().lower() in ("true", "yes", "1")


def read_leaderboard(path):
    with open(path, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def allocate(rows, magics, max_mult=2.0, min_mult=0.25, min_trades_per_year=0.0,
             require_holdout_pf=None):
    """Return allocation rows. Inactive rows carry risk_mult 0 and the reason they were excluded."""
    out = []
    scores = {}
    for r in rows:
        ea, symbol = r["ea"], r["symbol"]
        magic = magics.get(ea)
        base = {"ea": ea, "magic": magic if magic is not None else "", "symbol": symbol}
        reason = None
        if magic is None:
            reason = "no magic number in source"
        elif not _flag(r.get("pass", "")):
            failed = r.get("failed", "").strip()
            reason = "failed gates: " + failed if failed else "did not pass"
        else:
            pf, dd = _num(r.get("oos_pf")), _num(r.get("oos_max_dd_pct"))
            tpy = _num(r.get("oos_trades_per_year"))
            if pf is None or dd is None:
                reason = "missing OOS profit factor or drawdown"
            elif tpy is not None and tpy < min_trades_per_year:
                reason = f"trades per year {tpy:.0f} below {min_trades_per_year:.0f}"
            elif require_holdout_pf is not None:
                ho = _num(r.get("holdout_pf"))
                if ho is None or ho < require_holdout_pf:
                    reason = f"holdout profit factor {r.get('holdout_pf', '-')} below {require_holdout_pf}"
        if reason:
            out.append({**base, "risk_mult": "0.00", "weight": "0.0000", "status": "inactive", "reason": reason})
            continue
        # Drawdown floor of 1% stops a zero-drawdown row from dominating the weights.
        scores[(ea, symbol)] = min(pf, 3.0) / max(dd, 1.0)
        out.append({**base, "risk_mult": None, "weight": None, "status": "active", "reason": ""})

    total = sum(scores.values())
    n_active = len(scores)
    for row in out:
        if row["status"] != "active":
            continue
        share = scores[(row["ea"], row["symbol"])] / total if total > 0 else 1.0 / n_active
        # Scale so an equal split gives multiplier 1.0, then clamp.
        mult = min(max_mult, max(min_mult, share * n_active))
        row["risk_mult"] = f"{mult:.2f}"
        row["weight"] = f"{share:.4f}"
    return out


def write_allocation(rows, path):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=HEADER)
        w.writeheader()
        for r in rows:
            w.writerow({k: r[k] for k in HEADER})


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--leaderboard", default=str(HERE / "wf_runs" / "leaderboard.csv"))
    p.add_argument("--out", default=str(HERE / "wf_runs" / "portfolio_allocation.csv"))
    p.add_argument("--source-dir", default=str(SOURCE_DIR))
    p.add_argument("--max-mult", type=float, default=2.0, help="cap on any EA's risk multiplier")
    p.add_argument("--min-mult", type=float, default=0.25, help="floor on an active EA's multiplier")
    p.add_argument("--min-trades-per-year", type=float, default=0.0,
                   help="extra OOS trade-frequency floor on top of the pipeline gates")
    p.add_argument("--require-holdout-pf", type=float, default=None,
                   help="optional: also require holdout profit factor >= this value")
    args = p.parse_args(argv)

    if not Path(args.leaderboard).exists():
        print(f"No leaderboard at {args.leaderboard}. Run `run_pipeline.bat report` first.", file=sys.stderr)
        return 1
    magics = read_magics(args.source_dir)
    rows = read_leaderboard(args.leaderboard)
    alloc = allocate(rows, magics, max_mult=args.max_mult, min_mult=args.min_mult,
                     min_trades_per_year=args.min_trades_per_year,
                     require_holdout_pf=args.require_holdout_pf)
    write_allocation(alloc, args.out)
    active = [r for r in alloc if r["status"] == "active"]
    print(f"{len(active)} of {len(alloc)} EA/symbol rows active. Wrote {args.out}")
    for r in active:
        print(f"  {r['ea']} {r['symbol']} magic={r['magic']} risk_mult={r['risk_mult']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
