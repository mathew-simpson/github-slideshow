#!/usr/bin/env python3
"""Walk-forward optimization pipeline for the MT5 EAs.

Stages (run in order, each one is resumable):

  generate   write in-sample (IS) genetic-optimization .ini files for every
             EA x symbol x window in wf_plan.json
  run-is     launch terminal64.exe once per IS .ini (skips finished jobs)
  select     read each IS optimization report (.xml), pick robust parameters
             using IS data only, write the matching out-of-sample (OOS) .ini
  run-oos    launch terminal64.exe once per OOS .ini (single backtest, real ticks)
  report     parse OOS reports (.htm), aggregate across walk-forward windows,
             apply pass criteria and rank EAs -> leaderboard.md / .csv
  all        every stage above in sequence

Only the Python standard library is used. See README_walkforward.md.
"""

import argparse
import csv
import datetime as dt
import html
import json
import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

HERE = Path(__file__).resolve().parent

ENUM_VALUES = {
    "MODE_SMA": 0, "MODE_EMA": 1, "MODE_SMMA": 2, "MODE_LWMA": 3,
    "PERIOD_CURRENT": 0, "PERIOD_M1": 1, "PERIOD_M5": 5, "PERIOD_M15": 15,
    "PERIOD_M30": 30, "PERIOD_H1": 16385, "PERIOD_H4": 16388,
    "PERIOD_D1": 16408, "PERIOD_W1": 32769, "PERIOD_MN1": 49153,
    "PRICE_CLOSE": 1, "PRICE_OPEN": 2, "PRICE_HIGH": 3, "PRICE_LOW": 4,
    "PRICE_MEDIAN": 5, "PRICE_TYPICAL": 6, "PRICE_WEIGHTED": 7,
}


# --------------------------------------------------------------------------
# Plan and windows
# --------------------------------------------------------------------------

def load_plan(path):
    with open(path, encoding="utf-8") as f:
        plan = json.load(f)
    plan["_path"] = Path(path).resolve()
    return plan


def plan_dir(plan, key):
    p = Path(plan["settings"][key])
    return p if p.is_absolute() else plan["_path"].parent / p


def add_months(d, months):
    y, m = divmod(d.month - 1 + months, 12)
    return d.replace(year=d.year + y, month=m + 1, day=1)


def build_windows(wcfg):
    """Rolling walk-forward windows plus one 70/30 holdout split.

    Each window is (name, is_from, is_to, oos_from, oos_to) with inclusive
    end dates, which is how the Strategy Tester reads ToDate.
    """
    start = dt.date.fromisoformat(wcfg["start"])
    end = dt.date.fromisoformat(wcfg["end"])
    day = dt.timedelta(days=1)
    windows = []
    i = 0
    while True:
        is_from = add_months(start, i * wcfg["step_months"])
        oos_from = add_months(is_from, wcfg["is_months"])
        oos_to = add_months(oos_from, wcfg["oos_months"])
        if oos_to > end:
            break
        i += 1
        windows.append((f"W{i}", is_from, oos_from - day, oos_from, oos_to - day))
    split = wcfg.get("holdout_split")
    if split:
        total_months = (end.year - start.year) * 12 + end.month - start.month
        cut = add_months(start, round(total_months * split))
        windows.append(("HO", start, cut - day, cut, end - day))
    return windows


def years_between(a, b):
    return ((b - a).days + 1) / 365.25


# --------------------------------------------------------------------------
# EA source parsing (so every input is written explicitly to the .ini)
# --------------------------------------------------------------------------

INPUT_RE = re.compile(r"\binput\s+(?!group\b)([A-Za-z_]\w*)\s+([A-Za-z_]\w*)\s*=\s*([^;]+);")


def read_text(path):
    raw = Path(path).read_bytes()
    if raw.startswith(b"\xff\xfe") or raw.startswith(b"\xfe\xff"):
        return raw.decode("utf-16")
    if raw.startswith(b"\xef\xbb\xbf"):
        return raw[3:].decode("utf-8")
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return raw.decode("cp1252")


def parse_ea_inputs(source_path):
    """Return an ordered dict {name: (type, default_value_as_ini_text)}."""
    text = read_text(source_path)
    text = re.sub(r"//[^\n]*", "", text)
    inputs = {}
    for typ, name, value in INPUT_RE.findall(text):
        value = value.strip().strip('"')
        if value in ENUM_VALUES:
            value = str(ENUM_VALUES[value])
        inputs[name] = (typ, value)
    return inputs


def fmt_num(x):
    if isinstance(x, float):
        return f"{x:.10g}"
    return str(x)


# --------------------------------------------------------------------------
# .ini generation
# --------------------------------------------------------------------------

def tester_section(plan, ea, symbol, tf, date_from, date_to, report, optimize):
    s = plan["settings"]
    lines = [
        "[Tester]",
        f"Expert={s['expert_prefix']}{ea}",
        f"Symbol={symbol}",
        f"Period={tf}",
        f"Model={s['is_model'] if optimize else s['oos_model']}",
        f"ExecutionMode={s.get('execution_delay_ms', 0)}",
        f"FromDate={date_from:%Y.%m.%d}",
        f"ToDate={date_to:%Y.%m.%d}",
        "ForwardMode=0",
        f"Deposit={s['deposit']}",
        f"Currency={s['currency']}",
        f"Leverage={s['leverage']}",
        f"Optimization={2 if optimize else 0}",
        f"OptimizationCriterion={s['optimization_criterion']}",
        "Visual=0",
        f"Report={report}",
        "ReplaceReport=1",
        "ShutdownTerminal=1",
    ]
    return lines


def inputs_section(ea_inputs, optimize_ranges, fixed_values):
    lines = ["[TesterInputs]", "; name=value||start||step||stop||Y/N"]
    for name, (typ, default) in ea_inputs.items():
        if name in optimize_ranges:
            start, step, stop = optimize_ranges[name]
            lines.append(f"{name}={fmt_num(start)}||{fmt_num(start)}||{fmt_num(step)}||{fmt_num(stop)}||Y")
            continue
        value = fixed_values.get(name, default)
        if typ == "bool":
            lines.append(f"{name}={str(value).lower()}")
        else:
            lines.append(f"{name}={value}||{value}||0||{value}||N")
    return lines


def write_ini(path, lines, encoding):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding=encoding, newline="\r\n") as f:
        f.write("\n".join(lines) + "\n")


def job_id(ea, symbol, tf, win):
    return f"{ea}__{symbol}_{tf}_{win}"


def report_rel(plan, ea, symbol, tf, win, kind):
    return f"{plan['settings']['report_dir']}\\{ea}\\{symbol}_{tf}_{win}_{kind}"


def iter_jobs(plan, only=None):
    windows = build_windows(plan["windows"])
    for ea, cfg in plan["eas"].items():
        if ea.startswith("_") or (only and ea not in only):
            continue
        symbols = cfg.get("symbols", plan["settings"]["symbols"])
        for symbol in symbols:
            for win in windows:
                yield ea, cfg, symbol, cfg["timeframe"], win


def cmd_generate(plan, args):
    src_dir = plan_dir(plan, "ea_source_dir")
    work = plan_dir(plan, "work_dir")
    enc = plan["settings"]["ini_encoding"]
    n = 0
    for ea, cfg, symbol, tf, (win, is_from, is_to, _, _) in iter_jobs(plan, args.only):
        ea_inputs = parse_ea_inputs(src_dir / f"{ea}.mq5")
        missing = [p for p in cfg["optimize"] if p not in ea_inputs]
        if missing:
            sys.exit(f"{ea}: optimize keys not found in source: {missing}")
        jid = job_id(ea, symbol, tf, win)
        lines = tester_section(plan, ea, symbol, tf, is_from, is_to,
                               report_rel(plan, ea, symbol, tf, win, "IS"), True)
        lines.append("")
        lines += inputs_section(ea_inputs, cfg["optimize"], cfg.get("fixed", {}))
        write_ini(work / "is" / f"{jid}.ini", lines, enc)
        n += 1
    print(f"Wrote {n} IS optimization configs to {work / 'is'}")


# --------------------------------------------------------------------------
# Running the terminal
# --------------------------------------------------------------------------

def find_report(plan, rel, exts):
    base = plan_dir(plan, "data_dir") / rel.replace("\\", os.sep)
    for ext in exts:
        p = base.with_name(base.name + ext)
        if p.exists():
            return p
    return None


def run_stage(plan, args, kind, exts):
    s = plan["settings"]
    work = plan_dir(plan, "work_dir") / kind.lower()
    inis = sorted(work.glob("*.ini"))
    if args.only:
        inis = [p for p in inis if p.stem.split("__")[0] in args.only]
    if not inis:
        print(f"No {kind} configs in {work}; run the previous stage first.")
        return
    for i, ini in enumerate(inis, 1):
        ea, rest = ini.stem.split("__")
        symbol_tf, win = rest.rsplit("_", 1)
        symbol, tf = symbol_tf.rsplit("_", 1)
        rel = report_rel(plan, ea, symbol, tf, win, kind)
        if find_report(plan, rel, exts) and not args.force:
            print(f"[{i}/{len(inis)}] skip {ini.stem} (report exists)")
            continue
        cmd = [s["terminal"], f"/config:{ini}"]
        if s.get("portable"):
            cmd.append("/portable")
        print(f"[{i}/{len(inis)}] {kind} {ini.stem}", flush=True)
        if args.dry_run:
            print("   ", " ".join(cmd))
            continue
        try:
            subprocess.run(cmd, timeout=s["job_timeout_minutes"] * 60, check=False)
        except subprocess.TimeoutExpired:
            print(f"   timed out after {s['job_timeout_minutes']} min")
        if not find_report(plan, rel, exts):
            print(f"   WARNING: no report produced at {rel}{exts[0]}")


def cmd_run_is(plan, args):
    run_stage(plan, args, "IS", [".xml"])


def cmd_run_oos(plan, args):
    run_stage(plan, args, "OOS", [".htm", ".html"])


# --------------------------------------------------------------------------
# Parsing MT5 reports
# --------------------------------------------------------------------------

def parse_number(text):
    """'1 234.56' / '-12.30' / '1 234.56 (12.34%)' -> 1234.56 (first number)."""
    m = re.search(r"-?\d[\d\s ]*(?:[.,]\d+)?", text)
    if not m:
        return None
    s = re.sub(r"[\s ]", "", m.group(0)).replace(",", ".")
    return float(s)


def parse_percent(text):
    """Return the number directly followed by '%' in the text."""
    m = re.search(r"(-?\d[\d\s ]*(?:[.,]\d+)?)\s*%", text)
    return parse_number(m.group(1)) if m else None


def parse_optimization_xml(path):
    """Parse an MT5 optimization report (SpreadsheetML). Returns list of dicts."""
    text = read_text(path)
    text = re.sub(r"^<\?xml[^>]*\?>", "", text.lstrip())
    root = ET.fromstring(text)
    rows = []
    for row in root.iter():
        if not row.tag.endswith("Row"):
            continue
        cells = []
        for cell in row:
            if not cell.tag.endswith("Cell"):
                continue
            data = [d for d in cell if d.tag.endswith("Data")]
            cells.append(data[0].text if data and data[0].text is not None else "")
        rows.append(cells)
    if not rows:
        return []
    header = [h.strip() for h in rows[0]]
    passes = []
    for cells in rows[1:]:
        if len(cells) < len(header):
            continue
        rec = {}
        for h, v in zip(header, cells):
            try:
                rec[h] = float(v)
            except ValueError:
                rec[h] = v
        passes.append(rec)
    return passes


REPORT_LABELS = {
    "net_profit": "Total Net Profit",
    "gross_profit": "Gross Profit",
    "gross_loss": "Gross Loss",
    "profit_factor": "Profit Factor",
    "expected_payoff": "Expected Payoff",
    "recovery_factor": "Recovery Factor",
    "sharpe": "Sharpe Ratio",
    "equity_dd_rel": "Equity Drawdown Relative",
    "equity_dd_max": "Equity Drawdown Maximal",
    "total_trades": "Total Trades",
    "profit_trades": "Profit Trades (% of total)",
}


def parse_backtest_html(path):
    """Parse a single-test MT5 HTML report into a metrics dict."""
    text = read_text(path)
    cells = [html.unescape(re.sub(r"<[^>]+>", "", c)).strip()
             for c in re.findall(r"<td[^>]*>(.*?)</td>", text, re.S | re.I)]
    found = {}
    for i, c in enumerate(cells[:-1]):
        if c.endswith(":"):
            label = c[:-1].strip()
            if label not in found:
                found[label] = cells[i + 1]
    out = {}
    for key, label in REPORT_LABELS.items():
        raw = found.get(label)
        if raw is None:
            out[key] = None
        elif key == "equity_dd_rel":
            out[key] = parse_percent(raw)
        else:
            out[key] = parse_number(raw)
    if out.get("equity_dd_max") is not None:
        out["equity_dd_max_pct"] = parse_percent(found[REPORT_LABELS["equity_dd_max"]])
    pt = found.get(REPORT_LABELS["profit_trades"])
    out["win_rate"] = parse_percent(pt) if pt else None
    return out


# --------------------------------------------------------------------------
# Robust parameter selection (IS data only)
# --------------------------------------------------------------------------

def select_params(passes, opt_ranges, sel, is_years):
    """Pick parameters from IS optimization passes.

    Filters out passes with too few trades, an implausible profit factor or a
    deep drawdown, then either takes the best Result ("top") or the candidate
    among the top_k whose +/-1 step neighbourhood scores best on average
    ("plateau"), which favours stable regions over isolated spikes.
    """
    min_trades = sel["min_is_trades_per_year"] * is_years
    ok = [p for p in passes
          if p.get("Trades", 0) >= min_trades
          and p.get("Profit Factor", 0) <= sel["max_is_profit_factor"]
          and p.get("Equity DD %", 0) <= sel["max_is_equity_dd_pct"]
          and p.get("Profit", 0) > 0]
    if not ok:
        return None, "no IS pass met the trade/PF/DD filters"
    ok.sort(key=lambda p: p["Result"], reverse=True)
    if sel["method"] == "top":
        return ok[0], "top"
    names = [n for n in opt_ranges if n in ok[0]]

    def near(a, b):
        return all(abs(a[n] - b[n]) <= opt_ranges[n][1] * 1.0001 for n in names)

    best, best_score = None, None
    for cand in ok[: sel["top_k"]]:
        hood = [p["Result"] for p in passes if near(p, cand)]
        score = sum(hood) / len(hood)
        if best_score is None or score > best_score:
            best, best_score = cand, score
    return best, f"plateau (neighbourhood mean {best_score:.4g})"


def cmd_select(plan, args):
    src_dir = plan_dir(plan, "ea_source_dir")
    work = plan_dir(plan, "work_dir")
    enc = plan["settings"]["ini_encoding"]
    chosen = {}
    sel_path = work / "selected_params.json"
    if sel_path.exists():
        chosen = json.loads(sel_path.read_text(encoding="utf-8"))
    n = 0
    for ea, cfg, symbol, tf, (win, is_from, is_to, oos_from, oos_to) in iter_jobs(plan, args.only):
        jid = job_id(ea, symbol, tf, win)
        xml = find_report(plan, report_rel(plan, ea, symbol, tf, win, "IS"), [".xml"])
        if not xml:
            print(f"missing IS report for {jid}")
            continue
        passes = parse_optimization_xml(xml)
        best, why = select_params(passes, cfg["optimize"], plan["selection"],
                                  years_between(is_from, is_to))
        if best is None:
            print(f"{jid}: {why}; no OOS run")
            chosen[jid] = {"status": "no_candidate", "reason": why}
            continue
        params = {k: best[k] for k in cfg["optimize"]}
        chosen[jid] = {
            "status": "selected", "reason": why, "params": params,
            "is": {"profit": best.get("Profit"), "profit_factor": best.get("Profit Factor"),
                   "equity_dd_pct": best.get("Equity DD %"), "trades": best.get("Trades"),
                   "sharpe": best.get("Sharpe Ratio"), "passes": len(passes)},
        }
        ea_inputs = parse_ea_inputs(src_dir / f"{ea}.mq5")
        fixed = dict(cfg.get("fixed", {}))
        fixed.update({k: fmt_num(v) for k, v in params.items()})
        lines = tester_section(plan, ea, symbol, tf, oos_from, oos_to,
                               report_rel(plan, ea, symbol, tf, win, "OOS"), False)
        lines.append("")
        lines += inputs_section(ea_inputs, {}, fixed)
        write_ini(work / "oos" / f"{jid}.ini", lines, enc)
        n += 1
    sel_path.parent.mkdir(parents=True, exist_ok=True)
    sel_path.write_text(json.dumps(chosen, indent=2), encoding="utf-8")
    print(f"Wrote {n} OOS configs; selections saved to {sel_path}")


# --------------------------------------------------------------------------
# Aggregation, pass criteria and ranking
# --------------------------------------------------------------------------

def aggregate(per_window, crit):
    """Combine walk-forward OOS windows (not the holdout) into one verdict."""
    wf = [w for w in per_window if w["window"] != "HO" and w.get("oos")]
    if not wf:
        return None
    gp = sum(w["oos"]["gross_profit"] or 0 for w in wf)
    gl = abs(sum(w["oos"]["gross_loss"] or 0 for w in wf))
    trades = sum(w["oos"]["total_trades"] or 0 for w in wf)
    wins = sum((w["oos"]["total_trades"] or 0) * (w["oos"]["win_rate"] or 0) / 100 for w in wf)
    years = sum(w["oos_years"] for w in wf)
    is_pfs = sorted(w["is"]["profit_factor"] for w in wf if w["is"].get("profit_factor"))
    sharpes = [w["oos"]["sharpe"] for w in wf if w["oos"]["sharpe"] is not None]
    pf = gp / gl if gl else (float("inf") if gp else 0.0)
    is_pf_median = is_pfs[len(is_pfs) // 2] if is_pfs else None
    agg = {
        "windows": len(wf),
        "oos_net_profit": sum(w["oos"]["net_profit"] or 0 for w in wf),
        "oos_profit_factor": pf,
        "oos_max_equity_dd_pct": max(w["oos"]["equity_dd_rel"] or 0 for w in wf),
        "oos_trades": int(trades),
        "oos_trades_per_year": trades / years if years else 0,
        "oos_win_rate_pct": 100 * wins / trades if trades else 0,
        "oos_sharpe_mean": sum(sharpes) / len(sharpes) if sharpes else None,
        "is_profit_factor_median": is_pf_median,
        "wf_efficiency": pf / is_pf_median if is_pf_median else None,
        "profitable_windows": sum(1 for w in wf if (w["oos"]["net_profit"] or 0) > 0),
    }
    agg["profitable_window_frac"] = agg["profitable_windows"] / len(wf)
    checks = {
        "pf": agg["oos_profit_factor"] >= crit["min_oos_profit_factor"],
        "dd": agg["oos_max_equity_dd_pct"] <= crit["max_oos_equity_dd_pct"],
        "win_rate": agg["oos_win_rate_pct"] >= crit["min_oos_win_rate_pct"],
        "sharpe": (agg["oos_sharpe_mean"] or 0) >= crit["min_oos_sharpe"],
        "wfe": (agg["wf_efficiency"] or 0) >= crit["min_wf_efficiency"],
        "trades": agg["oos_trades_per_year"] >= crit["min_oos_trades_per_year"],
        "consistency": agg["profitable_window_frac"] >= crit["min_profitable_window_frac"],
    }
    agg["failed"] = [k for k, v in checks.items() if not v]
    agg["pass"] = not agg["failed"]
    return agg


def rank_key(row):
    a = row["agg"]
    return (not a["pass"], len(a["failed"]), -a["oos_profit_factor"],
            a["oos_max_equity_dd_pct"], -a["oos_trades"])


def collect_results(plan, only=None):
    work = plan_dir(plan, "work_dir")
    sel_path = work / "selected_params.json"
    chosen = json.loads(sel_path.read_text(encoding="utf-8")) if sel_path.exists() else {}
    groups = {}
    for ea, cfg, symbol, tf, (win, is_from, is_to, oos_from, oos_to) in iter_jobs(plan, only):
        jid = job_id(ea, symbol, tf, win)
        entry = {"window": win, "oos_from": oos_from.isoformat(), "oos_to": oos_to.isoformat(),
                 "oos_years": years_between(oos_from, oos_to),
                 "is": chosen.get(jid, {}).get("is", {}),
                 "params": chosen.get(jid, {}).get("params"), "oos": None}
        htm = find_report(plan, report_rel(plan, ea, symbol, tf, win, "OOS"), [".htm", ".html"])
        if htm:
            entry["oos"] = parse_backtest_html(htm)
        groups.setdefault((ea, symbol, tf), []).append(entry)
    rows = []
    for (ea, symbol, tf), per_window in groups.items():
        agg = aggregate(per_window, plan["pass_criteria"])
        if agg is None:
            continue
        ho = next((w for w in per_window if w["window"] == "HO" and w["oos"]), None)
        latest = [w for w in per_window if w["window"] != "HO" and w["params"]]
        rows.append({"ea": ea, "symbol": symbol, "tf": tf, "agg": agg,
                     "holdout": ho["oos"] if ho else None,
                     "latest_params": latest[-1]["params"] if latest else None,
                     "windows": per_window})
    rows.sort(key=rank_key)
    return rows


def fmt(x, nd=2):
    if x is None:
        return "-"
    if isinstance(x, float):
        return "inf" if x == float("inf") else f"{x:.{nd}f}"
    return str(x)


def cmd_report(plan, args):
    rows = collect_results(plan, args.only)
    out = Path(args.out) if args.out else plan_dir(plan, "work_dir")
    out.mkdir(parents=True, exist_ok=True)
    if not rows:
        print("No OOS reports found yet.")
        return

    with open(out / "leaderboard.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["rank", "ea", "symbol", "tf", "pass", "failed", "oos_pf", "oos_max_dd_pct",
                    "oos_trades", "oos_trades_per_year", "oos_win_rate_pct", "oos_sharpe_mean",
                    "oos_net_profit", "wf_efficiency", "profitable_windows", "windows",
                    "holdout_pf", "holdout_dd_pct", "holdout_trades", "latest_params"])
        for i, r in enumerate(rows, 1):
            a, ho = r["agg"], r["holdout"] or {}
            w.writerow([i, r["ea"], r["symbol"], r["tf"], a["pass"], ";".join(a["failed"]),
                        fmt(a["oos_profit_factor"], 3), fmt(a["oos_max_equity_dd_pct"]),
                        a["oos_trades"], fmt(a["oos_trades_per_year"], 1),
                        fmt(a["oos_win_rate_pct"], 1), fmt(a["oos_sharpe_mean"]),
                        fmt(a["oos_net_profit"]), fmt(a["wf_efficiency"]),
                        a["profitable_windows"], a["windows"],
                        fmt(ho.get("profit_factor")), fmt(ho.get("equity_dd_rel")),
                        fmt(ho.get("total_trades"), 0), json.dumps(r["latest_params"])])

    with open(out / "windows.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["ea", "symbol", "tf", "window", "oos_from", "oos_to", "is_pf", "is_dd_pct",
                    "is_trades", "oos_pf", "oos_dd_pct", "oos_trades", "oos_net_profit", "params"])
        for r in rows:
            for win in r["windows"]:
                o, s = win["oos"] or {}, win["is"]
                w.writerow([r["ea"], r["symbol"], r["tf"], win["window"], win["oos_from"],
                            win["oos_to"], fmt(s.get("profit_factor")), fmt(s.get("equity_dd_pct")),
                            fmt(s.get("trades"), 0), fmt(o.get("profit_factor")),
                            fmt(o.get("equity_dd_rel")), fmt(o.get("total_trades"), 0),
                            fmt(o.get("net_profit")), json.dumps(win["params"])])

    crit = plan["pass_criteria"]
    md = [
        "# Walk-forward leaderboard",
        "",
        f"Generated {dt.datetime.now():%Y-%m-%d %H:%M}. Ranked by: passes all gates, fewest "
        "failed gates, OOS profit factor (high), OOS max drawdown (low), OOS trades (high).",
        "",
        f"Gates: OOS PF >= {crit['min_oos_profit_factor']}, DD <= {crit['max_oos_equity_dd_pct']}%, "
        f"win rate >= {crit['min_oos_win_rate_pct']}%, Sharpe >= {crit['min_oos_sharpe']}, "
        f"WF efficiency >= {crit['min_wf_efficiency']}, trades/yr >= {crit['min_oos_trades_per_year']}, "
        f"profitable windows >= {crit['min_profitable_window_frac']:.0%}.",
        "",
        "| # | EA | Symbol | TF | Pass | OOS PF | Max DD % | Trades | Trades/yr | Win % | "
        "Sharpe | WFE | Win windows | Holdout PF | Failed |",
        "|---|----|--------|----|------|--------|----------|--------|-----------|-------|"
        "--------|-----|-------------|------------|--------|",
    ]
    for i, r in enumerate(rows, 1):
        a, ho = r["agg"], r["holdout"] or {}
        md.append(f"| {i} | {r['ea']} | {r['symbol']} | {r['tf']} | {'YES' if a['pass'] else 'no'} | "
                  f"{fmt(a['oos_profit_factor'])} | {fmt(a['oos_max_equity_dd_pct'])} | "
                  f"{a['oos_trades']} | {fmt(a['oos_trades_per_year'], 0)} | "
                  f"{fmt(a['oos_win_rate_pct'], 1)} | {fmt(a['oos_sharpe_mean'])} | "
                  f"{fmt(a['wf_efficiency'])} | {a['profitable_windows']}/{a['windows']} | "
                  f"{fmt(ho.get('profit_factor'))} | {', '.join(a['failed']) or '-'} |")
    passing = [r for r in rows if r["agg"]["pass"]]
    md += ["", "## Candidates for demo forward test", ""]
    if passing:
        for r in passing:
            md.append(f"- **{r['ea']}** {r['symbol']} {r['tf']}: latest-window params "
                      f"`{json.dumps(r['latest_params'])}`")
    else:
        md.append("None passed every gate. Check `failed` to see which gate is closest.")
    (out / "leaderboard.md").write_text("\n".join(md) + "\n", encoding="utf-8")
    print("\n".join(md[6:8 + len(rows)]))
    print(f"\nWrote {out / 'leaderboard.md'}, leaderboard.csv and windows.csv")


def cmd_all(plan, args):
    for fn in (cmd_generate, cmd_run_is, cmd_select, cmd_run_oos, cmd_report):
        fn(plan, args)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("stage", choices=["generate", "run-is", "select", "run-oos", "report", "all", "windows"])
    ap.add_argument("--plan", default=str(HERE / "wf_plan.json"))
    ap.add_argument("--only", nargs="*", help="limit to these EA names")
    ap.add_argument("--force", action="store_true", help="re-run jobs whose report already exists")
    ap.add_argument("--dry-run", action="store_true", help="print terminal commands without running them")
    ap.add_argument("--out", help="output folder for the report stage (default: work_dir)")
    args = ap.parse_args(argv)
    plan = load_plan(args.plan)
    if args.stage == "windows":
        for name, a, b, c, d in build_windows(plan["windows"]):
            print(f"{name}: IS {a} -> {b}   OOS {c} -> {d}")
        return
    {"generate": cmd_generate, "run-is": cmd_run_is, "select": cmd_select,
     "run-oos": cmd_run_oos, "report": cmd_report, "all": cmd_all}[args.stage](plan, args)


if __name__ == "__main__":
    main()
