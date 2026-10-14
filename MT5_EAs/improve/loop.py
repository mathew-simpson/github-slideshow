#!/usr/bin/env python3
"""Self-improvement loop for the MT5 EAs.

Each cycle proposes one small change per EA, backtests it against the EA's
current settings on in-sample (IS), out-of-sample (OOS) and holdout data,
keeps it only if it is better out of sample without giving up in-sample
quality, and records what was tried in changelog.jsonl so later cycles do
not repeat it.

Commands (run in this folder):

  init      seed state.json with each EA's current parameters
            (from the .mq5 defaults, optionally overridden by a sweep CSV)
  propose   open the next cycle: pick one change per EA and write tester
            .ini files to cycles/NNN/ini
  run       launch terminal64.exe once per .ini and copy the reports into
            cycles/NNN/reports (Windows, the MT5 PC only)
  ingest    parse cycles/NNN/reports into cycles/NNN/results.json
  evaluate  apply the acceptance gates, update state.json, append to
            changelog.jsonl, write cycles/NNN/SUMMARY.md and CHANGELOG.md
  status    print each EA's state and the open cycle

Only the Python standard library is used. See README.md and CYCLE.md.
"""

import argparse
import csv
import datetime as dt
import hashlib
import html
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SEGMENTS = ("is", "oos", "holdout")
VARIANTS = ("baseline", "candidate")

INPUT_RE = re.compile(r"\binput\s+(?!group\b)([A-Za-z_]\w*)\s+([A-Za-z_]\w*)\s*=\s*([^;]+);")

REPORT_LABELS = {
    "net_profit": "Total Net Profit",
    "gross_profit": "Gross Profit",
    "gross_loss": "Gross Loss",
    "profit_factor": "Profit Factor",
    "expected_payoff": "Expected Payoff",
    "recovery_factor": "Recovery Factor",
    "sharpe": "Sharpe Ratio",
    "equity_dd_rel": "Equity Drawdown Relative",
    "total_trades": "Total Trades",
    "profit_trades": "Profit Trades (% of total)",
}


# --------------------------------------------------------------------------
# Files
# --------------------------------------------------------------------------

class Paths:
    def __init__(self, root):
        self.root = Path(root)
        self.config = self.root / "loop_config.json"
        self.local_config = self.root / "loop_config.local.json"
        self.space = self.root / "search_space.json"
        self.plan = self.root.parent / "tester" / "wf_plan.json"
        self.ideas = self.root / "logic_ideas.json"
        self.state = self.root / "state.json"
        self.changelog = self.root / "changelog.jsonl"
        self.changelog_md = self.root / "CHANGELOG.md"
        self.sets = self.root / "sets"
        self.cycles = self.root / "cycles"

    def cycle_dir(self, n):
        return self.cycles / f"{n:03d}"


def read_json(path, default=None):
    path = Path(path)
    if not path.exists():
        return default
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def write_json(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(data, f, indent=2, sort_keys=False)
        f.write("\n")


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


def load_config(p):
    cfg = read_json(p.config)
    local = read_json(p.local_config, {})
    for section, values in local.items():
        if isinstance(values, dict) and isinstance(cfg.get(section), dict):
            cfg[section].update(values)
        else:
            cfg[section] = values
    return cfg


def load_space(p):
    """Per-EA search space. wf_plan.json wins when it is present."""
    plan = read_json(p.plan)
    if plan and "eas" in plan:
        return {k: {"timeframe": v["timeframe"], "optimize": v.get("optimize", {}),
                    **({"symbols": v["symbols"]} if "symbols" in v else {})}
                for k, v in plan["eas"].items() if not k.startswith("_")}
    return {k: v for k, v in read_json(p.space).items() if not k.startswith("_")}


def load_changelog(p):
    if not p.changelog.exists():
        return []
    entries = []
    with open(p.changelog, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                entries.append(json.loads(line))
    return entries


def append_changelog(p, entries):
    with open(p.changelog, "a", encoding="utf-8", newline="\n") as f:
        for e in entries:
            f.write(json.dumps(e, sort_keys=False) + "\n")


def empty_state():
    return {"cycle": 0, "open_cycle": None, "eas": {}}


# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

def num(x):
    """Normalise a numeric value so 15 and 15.0 compare and print alike."""
    if isinstance(x, bool) or x is None:
        return x
    x = round(float(x), 10)
    return int(x) if x == int(x) else x


def base_key(ea_state):
    blob = json.dumps({"params": ea_state.get("params", {}),
                       "flags": ea_state.get("logic_flags", {})}, sort_keys=True)
    return hashlib.sha1(blob.encode()).hexdigest()[:10]


def family_of(cfg, ea):
    for fam, members in cfg.get("families", {}).items():
        if ea in members:
            return fam
    return None


def parse_ea_inputs(source_path):
    text = re.sub(r"//[^\n]*", "", read_text(source_path))
    out = {}
    for typ, name, value in INPUT_RE.findall(text):
        value = value.strip().strip('"')
        try:
            out[name] = num(value)
        except ValueError:
            out[name] = value
    return out


def parse_params_cell(text):
    text = (text or "").strip()
    if not text:
        return {}
    if text.startswith("{"):
        return {k: num(v) for k, v in json.loads(text).items()}
    out = {}
    for part in re.split(r"[;|]", text):
        if "=" in part:
            k, v = part.split("=", 1)
            try:
                out[k.strip()] = num(v)
            except ValueError:
                out[k.strip()] = v.strip()
    return out


# --------------------------------------------------------------------------
# init
# --------------------------------------------------------------------------

def cmd_init(p, args):
    cfg = load_config(p)
    space = load_space(p)
    state = read_json(p.state) or empty_state()
    if state["eas"] and not args.force:
        sys.exit("state.json already has EAs; pass --force to re-seed parameters")
    ea_dir = Path(args.ea_dir) if args.ea_dir else (p.root / cfg["tester"]["ea_source_dir"])
    sweep = {}
    if args.sweep:
        with open(args.sweep, encoding="utf-8-sig", newline="") as f:
            for row in csv.DictReader(f):
                row = {k.strip().lower(): (v or "").strip() for k, v in row.items() if k}
                ea = row.get("ea") or row.get("expert") or row.get("name")
                if ea:
                    sweep[ea.replace(".mq5", "").replace(".ex5", "")] = row
    for ea, spec in space.items():
        params = {}
        src = ea_dir / f"{ea}.mq5"
        if src.exists():
            defaults = parse_ea_inputs(src)
            params = {k: defaults[k] for k in spec["optimize"] if k in defaults}
        for k, (start, _step, _stop) in spec["optimize"].items():
            params.setdefault(k, num(start))
        row = sweep.get(ea, {})
        for k, v in parse_params_cell(row.get("params")).items():
            if k in spec["optimize"]:
                params[k] = v
        prev = state["eas"].get(ea, {})
        state["eas"][ea] = {
            "params": params,
            "logic_flags": prev.get("logic_flags", {}),
            "baseline": None,
            "sweep_rank": num(row["rank"]) if row.get("rank") else prev.get("sweep_rank"),
            "params_source": ("sweep" if row.get("params") else "mq5" if src.exists() else "range_start"),
        }
    write_json(p.state, state)
    print(f"seeded {len(state['eas'])} EAs into {p.state.name}")


# --------------------------------------------------------------------------
# propose
# --------------------------------------------------------------------------

def trailing_rejections(entries, ea):
    n = 0
    for e in reversed([e for e in entries if e["ea"] == ea and e["verdict"] != "invalid"]):
        if e["verdict"] == "accepted":
            break
        n += 1
    return n


def param_proposal(ea, ea_state, spec, entries, frozen):
    key = base_key(ea_state)
    mine = [e for e in entries if e["ea"] == ea and e.get("kind") == "param" and e["verdict"] != "invalid"]
    tried_here = {(e["param"], num(e["to"])) for e in mine if e.get("base_key") == key}
    # A value that a kept change replaced already lost; never step back to it.
    tried_here |= {(e["param"], num(e["from"])) for e in mine if e["verdict"] == "accepted"}
    rejected_twice = {}
    for e in mine:
        if e["verdict"] == "rejected":
            k = (e["param"], num(e["to"]))
            rejected_twice[k] = rejected_twice.get(k, 0) + 1
    best = None
    for order, (name, (start, step, stop)) in enumerate(spec["optimize"].items()):
        if name in frozen:
            continue
        cur = num(ea_state["params"].get(name, start))
        hist = [e for e in mine if e["param"] == name]
        acc = sum(1 for e in hist if e["verdict"] == "accepted")
        prior = (acc + 1) / (len(hist) + 2)
        last_up = None
        for e in reversed(hist):
            if e["verdict"] == "accepted":
                last_up = num(e["to"]) > num(e["from"])
                break
        for direction in (1, -1):
            to = num(cur + direction * step)
            if to < num(start) - 1e-9 or to > num(stop) + 1e-9:
                continue
            if (name, to) in tried_here or rejected_twice.get((name, to), 0) >= 2:
                continue
            score = prior + (0.1 if last_up is not None and last_up == (direction > 0) else 0)
            rank = (-score, order, -direction)
            if best is None or rank < best[0]:
                best = (rank, {"kind": "param", "param": name, "from": cur, "to": to})
    return best[1] if best else None


def logic_proposal(ea, cfg, ideas, entries, ea_state):
    fam = family_of(cfg, ea)
    if fam == "grid":
        return None
    tried = {e.get("idea") for e in entries if e["ea"] == ea and e.get("kind") == "logic" and e["verdict"] != "invalid"}
    for idea in ideas:
        if idea["id"] in tried or idea["flag"] in ea_state.get("logic_flags", {}):
            continue
        if "all" in idea["families"] or fam in idea["families"]:
            return {"kind": "logic", "idea": idea["id"], "flag": idea["flag"], "change": idea["change"]}
    return None


def choose_proposal(ea, ea_state, spec, cfg, ideas, entries):
    frozen = set(cfg.get("frozen_params", {}).get(ea, []))
    budget = cfg["proposal"]["max_tries_per_ea_per_oos_window"]
    used = sum(1 for e in entries if e["ea"] == ea and e["verdict"] != "invalid")
    if used >= budget:
        return None, f"OOS budget spent ({used} tries); roll the OOS window before trying more"
    prefer_logic = trailing_rejections(entries, ea) >= cfg["proposal"]["logic_after_rejections"]
    order = (logic_proposal, param_proposal) if prefer_logic else (param_proposal, logic_proposal)
    for fn in order:
        prop = (logic_proposal(ea, cfg, ideas, entries, ea_state) if fn is logic_proposal
                else param_proposal(ea, ea_state, spec, entries, frozen))
        if prop:
            return prop, None
    return None, "no untried parameter moves or logic ideas left"


def fmt_ini(x):
    if isinstance(x, bool):
        return str(x).lower()
    if isinstance(x, float):
        return f"{x:.10g}"
    return str(x)


def ini_lines(cfg, ea, symbol, tf, seg, report, params, flags):
    t = cfg["tester"]
    d_from, d_to = (dt.date.fromisoformat(x) for x in cfg["segments"][seg])
    model = t["holdout_model"] if seg == "holdout" else t["model"]
    lines = [
        "[Tester]",
        f"Expert={t['expert_prefix']}{ea}",
        f"Symbol={symbol}",
        f"Period={tf}",
        f"Model={model}",
        f"FromDate={d_from:%Y.%m.%d}",
        f"ToDate={d_to:%Y.%m.%d}",
        "ForwardMode=0",
        f"Deposit={t['deposit']}",
        f"Currency={t['currency']}",
        f"Leverage={t['leverage']}",
        "Optimization=0",
        "Visual=0",
        f"Report={report}",
        "ReplaceReport=1",
        "ShutdownTerminal=1",
        "[TesterInputs]",
    ]
    for name, value in list(params.items()) + list(flags.items()):
        if isinstance(value, bool):
            lines.append(f"{name}={fmt_ini(value)}")
        else:
            v = fmt_ini(value)
            lines.append(f"{name}={v}||{v}||0||{v}||N")
    return lines


def write_ini(path, lines, encoding):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding=encoding, newline="\r\n") as f:
        f.write("\n".join(lines) + "\n")


def cmd_propose(p, args):
    cfg = load_config(p)
    space = load_space(p)
    ideas = read_json(p.ideas)["ideas"]
    state = read_json(p.state)
    if not state or not state["eas"]:
        sys.exit("no state.json; run `loop.py init` first")
    if state.get("open_cycle") and not args.force:
        sys.exit(f"cycle {state['open_cycle']} is still open; evaluate it or pass --force")
    entries = load_changelog(p)
    n = state["cycle"] + 1
    cdir = p.cycle_dir(n)
    if cdir.exists():
        shutil.rmtree(cdir)
    proposals, skipped = {}, {}
    eas = [e for e in space if not args.only or e in args.only]
    for ea in eas:
        ea_state = state["eas"].get(ea)
        if ea_state is None:
            skipped[ea] = "not in state.json; re-run init"
            continue
        prop, why = choose_proposal(ea, ea_state, space[ea], cfg, ideas, entries)
        if not prop:
            skipped[ea] = why
            continue
        prop["base_key"] = base_key(ea_state)
        prop["needs_baseline"] = not ea_state.get("baseline")
        proposals[ea] = prop
        symbol = space[ea].get("symbols", [cfg["tester"]["symbol"]])[0]
        tf = space[ea]["timeframe"]
        cand_params = dict(ea_state["params"])
        cand_flags = dict(ea_state.get("logic_flags", {}))
        if prop["kind"] == "param":
            cand_params[prop["param"]] = prop["to"]
        else:
            cand_flags[prop["flag"]] = True
        variants = {"candidate": (cand_params, cand_flags)}
        if prop["needs_baseline"]:
            variants["baseline"] = (ea_state["params"], ea_state.get("logic_flags", {}))
        for variant, (params, flags) in variants.items():
            for seg in SEGMENTS:
                name = f"{ea}__{variant}__{seg}"
                report = f"{cfg['tester']['report_dir']}\\{n:03d}\\{name}"
                write_ini(cdir / "ini" / f"{name}.ini",
                          ini_lines(cfg, ea, symbol, tf, seg, report, params, flags),
                          cfg["tester"]["ini_encoding"])
    write_json(cdir / "proposals.json", {"cycle": n, "created": dt.date.today().isoformat(),
                                         "proposals": proposals, "skipped": skipped})
    state["open_cycle"] = n
    write_json(p.state, state)
    logic = [ea for ea, pr in proposals.items() if pr["kind"] == "logic"]
    print(f"cycle {n:03d}: {len(proposals)} proposals, {len(skipped)} skipped, "
          f"{len(list((cdir / 'ini').glob('*.ini')))} tester jobs")
    for ea, pr in proposals.items():
        what = (f"{pr['param']} {pr['from']} -> {pr['to']}" if pr["kind"] == "param"
                else f"logic {pr['idea']} ({pr['flag']}=true)")
        print(f"  {ea}: {what}{'  [+baseline]' if pr['needs_baseline'] else ''}")
    for ea, why in skipped.items():
        print(f"  {ea}: skipped, {why}")
    if logic:
        print("logic proposals need the flag added to the .mq5 before `run`; see CYCLE.md step 3")


# --------------------------------------------------------------------------
# run (Windows, MT5 PC)
# --------------------------------------------------------------------------

# Demo accounts log "trading has been enabled, demo account - hedging mode"; live ones omit ", demo account".
LOGIN_RE = re.compile(r"'(\d+)': trading has been enabled(?:, demo account)? - (netting|hedging) mode", re.I)


def account_check(t):
    """Read the terminal journal and return (ok, message) for the account the tester will inherit.

    The tester runs on the login of the terminal it is started from. Backtests are only
    valid on a hedging account, and the loop only ever runs on logins listed in
    tester.allowed_logins (demo accounts), so a real-money terminal is never touched.
    """
    allowed = {str(x) for x in t.get("allowed_logins", [])}
    if not allowed:
        return False, "tester.allowed_logins is empty; list the demo login(s) the tester may run on"
    logs = sorted((Path(t["data_dir"]) / "logs").glob("*.log"))
    last = None
    for log in reversed(logs):
        hits = LOGIN_RE.findall(read_text(log))
        if hits:
            last = hits[-1]
            break
    if not last:
        return False, f"no login line found in {Path(t['data_dir']) / 'logs'}; open the terminal once so it logs in"
    login, mode = last
    if login not in allowed:
        return False, f"terminal is logged into {login}, which is not in tester.allowed_logins {sorted(allowed)}"
    if mode.lower() != "hedging":
        return False, f"account {login} is in {mode} mode; the EAs need a hedging account"
    return True, f"account {login}, hedging mode"


def cmd_run(p, args):
    cfg = load_config(p)
    n = args.cycle or read_json(p.state)["open_cycle"]
    cdir = p.cycle_dir(n)
    t = cfg["tester"]
    data_dir = Path(t["data_dir"])
    ok, msg = account_check(t)
    print(f"account check: {msg}")
    if not ok and not args.dry_run:
        sys.exit("refusing to run backtests: " + msg)
    out = cdir / "reports"
    out.mkdir(parents=True, exist_ok=True)
    inis = sorted((cdir / "ini").glob("*.ini"))
    for i, ini in enumerate(inis, 1):
        name = ini.stem
        src = data_dir / t["report_dir"] / f"{n:03d}" / f"{name}.htm"
        dst = out / f"{name}.htm"
        if dst.exists() and not args.force:
            continue
        cmd = [t["terminal"], f"/config:{ini.resolve()}"] + (["/portable"] if t.get("portable") else [])
        print(f"[{i}/{len(inis)}] {name}")
        if args.dry_run:
            print("   ", " ".join(f'"{c}"' if " " in c else c for c in cmd))
            continue
        try:
            subprocess.run(cmd, timeout=t["job_timeout_minutes"] * 60, check=False)
        except subprocess.TimeoutExpired:
            print(f"    timed out after {t['job_timeout_minutes']} min")
            continue
        if src.exists():
            shutil.copy2(src, dst)
        else:
            print(f"    no report at {src}")


# --------------------------------------------------------------------------
# ingest
# --------------------------------------------------------------------------

def parse_number(text):
    m = re.search(r"-?\d[\d\s ]*(?:[.,]\d+)?", text)
    if not m:
        return None
    return float(re.sub(r"[\s ]", "", m.group(0)).replace(",", "."))


def parse_percent(text):
    m = re.search(r"(-?\d[\d\s ]*(?:[.,]\d+)?)\s*%", text)
    return parse_number(m.group(1)) if m else None


def parse_report(path):
    """Single-backtest MT5 HTML report -> metrics dict (English labels)."""
    text = read_text(path)
    cells = [html.unescape(re.sub(r"<[^>]+>", "", c)).strip()
             for c in re.findall(r"<td[^>]*>(.*?)</td>", text, re.S | re.I)]
    found = {}
    for i, c in enumerate(cells[:-1]):
        if c.endswith(":"):
            found.setdefault(c[:-1].strip(), cells[i + 1])
    out = {}
    for key, label in REPORT_LABELS.items():
        raw = found.get(label)
        if raw is None:
            out[key] = None
        elif key in ("equity_dd_rel", "profit_trades"):
            out[key] = parse_percent(raw)
        else:
            out[key] = parse_number(raw)
    out["win_rate"] = out.pop("profit_trades")
    # Margin stop-out deals carry an "so 50.00%/..." comment; such a run says nothing about the strategy.
    out["stopped_out"] = bool(re.search(r">\s*so[:\s]\s*\d+(?:[.,]\d+)?%", text, re.I) or
                              re.search(r"stop[\s-]?out", text, re.I))
    if out["total_trades"] is not None:
        out["total_trades"] = int(out["total_trades"])
    return out


def cmd_ingest(p, args):
    n = args.cycle or read_json(p.state)["open_cycle"]
    cdir = p.cycle_dir(n)
    results = {}
    for rep in sorted((cdir / "reports").glob("*.htm*")):
        parts = rep.stem.split("__")
        if len(parts) != 3 or parts[1] not in VARIANTS or parts[2] not in SEGMENTS:
            continue
        ea, variant, seg = parts
        results.setdefault(ea, {}).setdefault(variant, {})[seg] = parse_report(rep)
    write_json(cdir / "results.json", {"cycle": n, "results": results})
    print(f"cycle {n:03d}: parsed {sum(len(s) for v in results.values() for s in v.values())} reports")


# --------------------------------------------------------------------------
# evaluate
# --------------------------------------------------------------------------

def pct_change(new, old):
    if old in (None, 0) or new is None:
        return None
    return (new - old) / abs(old) * 100.0


def judge(base, cand, acc):
    """Return (verdict, reasons). base/cand are {segment: metrics}."""
    for label, m in (("baseline", base), ("candidate", cand)):
        for seg in ("is", "oos"):
            if not m or not m.get(seg) or m[seg].get("profit_factor") is None:
                return "invalid", [f"{label} {seg} report missing or unparsed"]
    for label, m in (("baseline", base), ("candidate", cand)):
        empty = [seg for seg in ("is", "oos") if not m[seg].get("total_trades")]
        if empty:
            return "invalid", [f"{label} {', '.join(empty)} has no trades (aborted or blocked test)"]
        hit = [seg for seg in SEGMENTS if (m.get(seg) or {}).get("stopped_out")]
        if hit:
            return "invalid", [f"{label} hit a margin stop-out in {', '.join(hit)} (check the tester account is hedging)"]
    b_is, b_oos, c_is, c_oos = base["is"], base["oos"], cand["is"], cand["oos"]
    fails = []
    if (c_oos["total_trades"] or 0) < acc["min_oos_trades"]:
        fails.append(f"OOS trades {c_oos['total_trades']} < {acc['min_oos_trades']}")
    gain = pct_change(c_oos["profit_factor"], b_oos["profit_factor"])
    if gain is None or gain < acc["min_oos_pf_gain_pct"]:
        fails.append(f"OOS PF {b_oos['profit_factor']} -> {c_oos['profit_factor']} "
                     f"(needs +{acc['min_oos_pf_gain_pct']}%)")
    b_dd, c_dd = b_oos.get("equity_dd_rel"), c_oos.get("equity_dd_rel")
    if b_dd is not None and c_dd is not None and c_dd > b_dd * (1 + acc["max_oos_dd_worsening_pct"] / 100) + 0.5:
        fails.append(f"OOS drawdown {b_dd}% -> {c_dd}%")
    if c_is["profit_factor"] < b_is["profit_factor"] * acc["min_is_pf_ratio"]:
        fails.append(f"IS PF fell {b_is['profit_factor']} -> {c_is['profit_factor']}")
    if c_is["profit_factor"] > acc["max_is_profit_factor"]:
        fails.append(f"IS PF {c_is['profit_factor']} above {acc['max_is_profit_factor']} (curve-fit flag)")
    for seg in ("is", "oos"):
        bt, ct = base[seg]["total_trades"] or 0, cand[seg]["total_trades"] or 0
        if bt and ct < bt * acc["min_trade_ratio"]:
            fails.append(f"{seg.upper()} trades fell {bt} -> {ct}")
    if not fails:
        b_h, c_h = (base.get("holdout") or {}), (cand.get("holdout") or {})
        if b_h.get("profit_factor") is None or c_h.get("profit_factor") is None:
            return "invalid", ["holdout report missing for an otherwise accepted change"]
        if c_h["profit_factor"] < b_h["profit_factor"] * acc["min_holdout_pf_ratio"]:
            fails.append(f"holdout PF fell {b_h['profit_factor']} -> {c_h['profit_factor']}")
    return ("rejected", fails) if fails else ("accepted", [])


def describe(prop):
    if prop["kind"] == "param":
        return f"{prop['param']} {prop['from']} -> {prop['to']}"
    return f"logic `{prop['idea']}` ({prop['flag']}=true)"


def lesson(ea, prop, verdict, reasons, base, cand):
    what = describe(prop)
    if verdict == "invalid":
        return f"{what}: not judged ({reasons[0]}); will be retried"
    b, c = base["oos"]["profit_factor"], cand["oos"]["profit_factor"]
    head = f"{what}: OOS PF {b} -> {c}"
    if verdict == "accepted":
        return head + "; kept, now the baseline"
    return head + "; dropped (" + "; ".join(reasons) + ")"


def write_set_file(p, cfg, ea, ea_state):
    lines = [f"; {ea} settings kept by the improvement loop, cycle {ea_state.get('updated_cycle')}"]
    for name, value in list(ea_state["params"].items()) + list(ea_state.get("logic_flags", {}).items()):
        v = fmt_ini(value)
        lines.append(f"{name}={v}" if isinstance(value, bool) else f"{name}={v}||{v}||0||{v}||N")
    write_ini(p.sets / f"{ea}.set", lines, cfg["tester"]["ini_encoding"])


def fmt(x, nd=2):
    if x is None:
        return "-"
    return f"{x:.{nd}f}" if isinstance(x, float) else str(x)


def metrics_row(label, m):
    m = m or {}
    cells = []
    for seg in SEGMENTS:
        s = m.get(seg) or {}
        cells.append(f"{fmt(s.get('profit_factor'))} / {fmt(s.get('equity_dd_rel'))}% / {fmt(s.get('total_trades'))}")
    return f"| {label} | " + " | ".join(cells) + " |"


def cmd_evaluate(p, args):
    cfg = load_config(p)
    state = read_json(p.state)
    n = args.cycle or state.get("open_cycle")
    if not n:
        sys.exit("no open cycle")
    cdir = p.cycle_dir(n)
    props = read_json(cdir / "proposals.json")
    results = (read_json(cdir / "results.json") or {}).get("results", {})
    today = dt.date.today().isoformat()
    entries, rows = [], []
    for ea, prop in props["proposals"].items():
        ea_state = state["eas"][ea]
        r = results.get(ea, {})
        if r.get("baseline") and not ea_state.get("baseline"):
            ea_state["baseline"] = r["baseline"]
        base = ea_state.get("baseline") or r.get("baseline")
        cand = r.get("candidate")
        verdict, reasons = judge(base, cand, cfg["acceptance"])
        entry = {"cycle": n, "date": today, "ea": ea, **{k: prop[k] for k in prop if k != "needs_baseline"},
                 "verdict": verdict, "reasons": reasons,
                 "baseline": base, "candidate": cand}
        entry["lesson"] = lesson(ea, prop, verdict, reasons, base, cand)
        entries.append(entry)
        if verdict == "accepted":
            if prop["kind"] == "param":
                ea_state["params"][prop["param"]] = prop["to"]
            else:
                ea_state.setdefault("logic_flags", {})[prop["flag"]] = True
            ea_state["baseline"] = cand
            ea_state["updated_cycle"] = n
            write_set_file(p, cfg, ea, ea_state)
        rows.append((ea, prop, verdict, entry["lesson"], base, cand))
    append_changelog(p, entries)
    state["cycle"] = n
    state["open_cycle"] = None
    write_json(p.state, state)
    write_summary(cdir, n, props, rows, cfg)
    write_changelog_md(p)
    counts = {v: sum(1 for r in rows if r[2] == v) for v in ("accepted", "rejected", "invalid")}
    print(f"cycle {n:03d}: {counts['accepted']} kept, {counts['rejected']} dropped, {counts['invalid']} not judged")


def write_summary(cdir, n, props, rows, cfg):
    seg = cfg["segments"]
    out = [f"# Improvement cycle {n:03d}", "",
           f"IS {seg['is'][0]} to {seg['is'][1]}, OOS {seg['oos'][0]} to {seg['oos'][1]}, "
           f"holdout {seg['holdout'][0]} to {seg['holdout'][1]}. "
           "Cells are profit factor / relative equity drawdown / trades.", ""]
    for verdict, title in (("accepted", "Kept"), ("rejected", "Dropped"), ("invalid", "Not judged")):
        sel = [r for r in rows if r[2] == verdict]
        out.append(f"## {title} ({len(sel)})")
        out.append("")
        if not sel:
            out += ["None.", ""]
            continue
        for ea, prop, _v, les, base, cand in sel:
            out += [f"**{ea}**: {les}", "",
                    "| | IS | OOS | Holdout |", "|---|---|---|---|",
                    metrics_row("baseline", base), metrics_row("candidate", cand), ""]
    if props.get("skipped"):
        out += ["## Skipped", ""] + [f"- {ea}: {why}" for ea, why in props["skipped"].items()] + [""]
    (cdir / "SUMMARY.md").write_text("\n".join(out), encoding="utf-8")


def write_changelog_md(p):
    entries = load_changelog(p)
    out = ["# Improvement loop changelog", "",
           "Generated from `changelog.jsonl` by `loop.py evaluate`. Newest cycle first. "
           "Every change tried is listed, kept or not, so later cycles skip what already failed.", ""]
    by_cycle = {}
    for e in entries:
        by_cycle.setdefault(e["cycle"], []).append(e)
    for n in sorted(by_cycle, reverse=True):
        es = by_cycle[n]
        kept = sum(1 for e in es if e["verdict"] == "accepted")
        out += [f"## Cycle {n:03d} ({es[0]['date']}): {kept} kept of {len(es)}", ""]
        for e in sorted(es, key=lambda e: (e["verdict"] != "accepted", e["ea"])):
            mark = {"accepted": "kept", "rejected": "dropped", "invalid": "not judged"}[e["verdict"]]
            out.append(f"- {mark}: **{e['ea']}** {e['lesson']}")
        out.append("")
    p.changelog_md.write_text("\n".join(out), encoding="utf-8")


# --------------------------------------------------------------------------
# status
# --------------------------------------------------------------------------

def cmd_status(p, args):
    state = read_json(p.state)
    if not state:
        print("no state.json yet; run `loop.py init`")
        return
    entries = load_changelog(p)
    print(f"last closed cycle: {state['cycle']}, open cycle: {state.get('open_cycle')}")
    for ea, s in state["eas"].items():
        tries = [e for e in entries if e["ea"] == ea and e["verdict"] != "invalid"]
        kept = sum(1 for e in tries if e["verdict"] == "accepted")
        oos = ((s.get("baseline") or {}).get("oos") or {}).get("profit_factor")
        print(f"  {ea}: OOS PF {fmt(oos)}, {kept}/{len(tries)} kept, flags {sorted(s.get('logic_flags', {}))}")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=str(HERE), help="loop folder (default: this script's folder)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("init")
    s.add_argument("--sweep", help="sweep CSV with an `ea` column and optional `params`, `rank`")
    s.add_argument("--ea-dir", help="folder with the .mq5 files (default: tester.ea_source_dir)")
    s.add_argument("--force", action="store_true")
    s = sub.add_parser("propose")
    s.add_argument("--only", nargs="*")
    s.add_argument("--force", action="store_true")
    for name in ("run", "ingest", "evaluate"):
        s = sub.add_parser(name)
        s.add_argument("--cycle", type=int)
        if name == "run":
            s.add_argument("--dry-run", action="store_true")
            s.add_argument("--force", action="store_true")
    sub.add_parser("status")
    args = ap.parse_args(argv)
    p = Paths(args.root)
    {"init": cmd_init, "propose": cmd_propose, "run": cmd_run, "ingest": cmd_ingest,
     "evaluate": cmd_evaluate, "status": cmd_status}[args.cmd](p, args)


if __name__ == "__main__":
    main()
