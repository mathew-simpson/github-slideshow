"""Offline tests for loop.py: python -m unittest test_loop"""

import json
import shutil
import tempfile
import unittest
from pathlib import Path

import loop

HERE = Path(__file__).resolve().parent


def report_html(pf, dd, trades, win=50.0):
    gp = 1000.0 * pf
    rows = [("Total Net Profit:", f"{gp - 1000:.2f}"), ("Gross Profit:", f"{gp:.2f}"),
            ("Gross Loss:", "-1 000.00"), ("Profit Factor:", f"{pf:.2f}"),
            ("Expected Payoff:", "1.00"), ("Recovery Factor:", "1.10"), ("Sharpe Ratio:", "0.90"),
            ("Equity Drawdown Relative:", f"{dd:.2f}% (500.00)"), ("Total Trades:", str(trades)),
            ("Profit Trades (% of total):", f"{int(trades * win / 100)} ({win:.2f}%)")]
    body = "".join(f"<tr><td nowrap>{k}</td><td><b>{v}</b></td></tr>" for k, v in rows)
    return f"<html><body><table>{body}</table></body></html>"


class LoopTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.root = self.tmp / "improve"
        self.root.mkdir()
        for name in ("loop_config.json", "search_space.json", "logic_ideas.json"):
            shutil.copy(HERE / name, self.root / name)
        (self.tmp / "EA1_MACrossover_ATR.mq5").write_text(
            "input int FastMA_Period = 20; // fast\ninput int SlowMA_Period = 50;\n"
            "input double ATR_SL_Mult = 1.5;\ninput double ATR_TP_Mult = 3.0;\ninput double TrailATRMult = 1.0;\n")
        self.p = loop.Paths(self.root)

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def run_cli(self, *argv):
        loop.main(["--root", str(self.root), *argv])

    def state(self):
        return json.loads(self.p.state.read_text())

    def write_reports(self, n, spec):
        rdir = self.p.cycle_dir(n) / "reports"
        rdir.mkdir(parents=True, exist_ok=True)
        for name, (pf, dd, trades) in spec.items():
            (rdir / f"{name}.htm").write_text(report_html(pf, dd, trades), encoding="utf-16")

    def full_reports(self, ea, base, cand, n, with_baseline=True):
        spec = {}
        for variant, segs in (("baseline", base), ("candidate", cand)):
            if variant == "baseline" and not with_baseline:
                continue
            for seg, vals in zip(loop.SEGMENTS, segs):
                spec[f"{ea}__{variant}__{seg}"] = vals
        self.write_reports(n, spec)

    def test_parse_report(self):
        f = self.tmp / "r.htm"
        f.write_text(report_html(1.42, 7.5, 120), encoding="utf-16")
        m = loop.parse_report(f)
        self.assertAlmostEqual(m["profit_factor"], 1.42)
        self.assertAlmostEqual(m["equity_dd_rel"], 7.5)
        self.assertEqual(m["total_trades"], 120)
        self.assertAlmostEqual(m["gross_loss"], -1000.0)
        self.assertAlmostEqual(m["win_rate"], 50.0)

    def test_init_reads_mq5_defaults_and_sweep(self):
        sweep = self.tmp / "sweep.csv"
        sweep.write_text("EA,rank,params\nEA2_RSI_MeanReversion,3,RSI_Period=9;OversoldLevel=25\n")
        self.run_cli("init", "--ea-dir", str(self.tmp), "--sweep", str(sweep))
        s = self.state()["eas"]
        self.assertEqual(s["EA1_MACrossover_ATR"]["params"]["FastMA_Period"], 20)
        self.assertEqual(s["EA1_MACrossover_ATR"]["params_source"], "mq5")
        self.assertEqual(s["EA2_RSI_MeanReversion"]["params"]["RSI_Period"], 9)
        self.assertEqual(s["EA2_RSI_MeanReversion"]["sweep_rank"], 3)

    def test_full_cycle_accept_then_no_repeat(self):
        ea = "EA1_MACrossover_ATR"
        self.run_cli("init", "--ea-dir", str(self.tmp))
        self.run_cli("propose", "--only", ea)
        props = json.loads((self.p.cycle_dir(1) / "proposals.json").read_text())["proposals"]
        prop = props[ea]
        self.assertEqual((prop["param"], prop["from"], prop["to"]), ("FastMA_Period", 20, 25))
        inis = sorted(x.name for x in (self.p.cycle_dir(1) / "ini").glob("*.ini"))
        self.assertEqual(len(inis), 6)
        ini = (self.p.cycle_dir(1) / "ini" / f"{ea}__candidate__oos.ini").read_text(encoding="utf-16")
        self.assertIn("FastMA_Period=25||25||0||25||N", ini)
        self.assertIn("FromDate=2023.01.01", ini)

        self.full_reports(ea, [(1.20, 10, 400), (1.10, 8, 150), (1.05, 6, 40)],
                          [(1.22, 10, 390), (1.20, 8, 140), (1.08, 6, 38)], 1)
        self.run_cli("ingest")
        self.run_cli("evaluate")
        s = self.state()
        self.assertEqual(s["eas"][ea]["params"]["FastMA_Period"], 25)
        self.assertAlmostEqual(s["eas"][ea]["baseline"]["oos"]["profit_factor"], 1.20)
        self.assertIsNone(s["open_cycle"])
        self.assertTrue((self.p.sets / f"{ea}.set").exists())
        self.assertIn("kept", self.p.changelog_md.read_text())

        # Cycle 2: baseline is cached, momentum keeps pushing the same parameter upward.
        self.run_cli("propose", "--only", ea)
        prop = json.loads((self.p.cycle_dir(2) / "proposals.json").read_text())["proposals"][ea]
        self.assertFalse(prop["needs_baseline"])
        self.assertEqual((prop["param"], prop["to"]), ("FastMA_Period", 30))
        self.assertEqual(len(list((self.p.cycle_dir(2) / "ini").glob("*.ini"))), 3)
        self.full_reports(ea, None, [(1.22, 10, 390), (1.15, 8, 140), (1.0, 6, 38)], 2, with_baseline=False)
        self.run_cli("ingest")
        self.run_cli("evaluate")
        self.assertEqual(self.state()["eas"][ea]["params"]["FastMA_Period"], 25)

        # Cycle 3: the rejected move is not proposed again from the same baseline.
        self.run_cli("propose", "--only", ea)
        prop = json.loads((self.p.cycle_dir(3) / "proposals.json").read_text())["proposals"][ea]
        self.assertNotIn((prop.get("param"), prop.get("to")), {("FastMA_Period", 30), ("FastMA_Period", 20)})

    def test_gates(self):
        acc = json.loads((HERE / "loop_config.json").read_text())["acceptance"]
        m = lambda pf, dd, t: {"profit_factor": pf, "equity_dd_rel": dd, "total_trades": t}
        base = {"is": m(1.2, 10, 400), "oos": m(1.1, 8, 150), "holdout": m(1.0, 5, 40)}
        ok = {"is": m(1.2, 10, 400), "oos": m(1.2, 8, 150), "holdout": m(1.0, 5, 40)}
        self.assertEqual(loop.judge(base, ok, acc)[0], "accepted")
        is_drop = dict(ok, **{"is": m(1.0, 10, 400)})
        self.assertEqual(loop.judge(base, is_drop, acc)[0], "rejected")
        dd_up = dict(ok, **{"oos": m(1.2, 12, 150)})
        self.assertEqual(loop.judge(base, dd_up, acc)[0], "rejected")
        few = dict(ok, **{"oos": m(1.2, 8, 20)})
        self.assertEqual(loop.judge(base, few, acc)[0], "rejected")
        holdout_bad = dict(ok, **{"holdout": m(0.8, 5, 40)})
        self.assertEqual(loop.judge(base, holdout_bad, acc)[0], "rejected")
        self.assertEqual(loop.judge(None, ok, acc)[0], "invalid")
        aborted = dict(ok, **{"is": m(0.0, 0, 0)})
        self.assertEqual(loop.judge(base, aborted, acc)[0], "invalid")
        so = dict(ok, **{"oos": dict(m(1.5, 8, 150), stopped_out=True)})
        self.assertEqual(loop.judge(base, so, acc)[0], "invalid")

    def test_stop_out_detected(self):
        f = self.tmp / "so.htm"
        f.write_text(report_html(0.4, 99, 900).replace("</table>",
                     "<tr><td>2015.03.02</td><td>so 50.00%/48.10%/1 234.00</td></tr></table>"), encoding="utf-16")
        self.assertTrue(loop.parse_report(f)["stopped_out"])
        g = self.tmp / "ok.htm"
        g.write_text(report_html(1.2, 5, 100), encoding="utf-16")
        self.assertFalse(loop.parse_report(g)["stopped_out"])

    def test_logic_after_rejections_and_open_cycle_guard(self):
        ea = "EA2_RSI_MeanReversion"
        self.run_cli("init", "--ea-dir", str(self.tmp))
        entries = [{"cycle": i, "date": "2026-10-13", "ea": ea, "kind": "param", "param": "RSI_Period",
                    "from": 7, "to": 9 + i, "base_key": "x", "verdict": "rejected", "reasons": [], "lesson": ""}
                   for i in range(3)]
        loop.append_changelog(self.p, entries)
        self.run_cli("propose", "--only", ea)
        prop = json.loads((self.p.cycle_dir(1) / "proposals.json").read_text())["proposals"][ea]
        self.assertEqual(prop["kind"], "logic")
        self.assertEqual(prop["idea"], "session_filter")
        ini = (self.p.cycle_dir(1) / "ini" / f"{ea}__candidate__is.ini").read_text(encoding="utf-16")
        self.assertIn("UseSessionFilter=true", ini)
        with self.assertRaises(SystemExit):
            self.run_cli("propose", "--only", ea)

    def test_frozen_grid_params_never_proposed(self):
        ea = "EA11_Grid_Recovery"
        self.run_cli("init", "--ea-dir", str(self.tmp))
        self.run_cli("propose", "--only", ea)
        prop = json.loads((self.p.cycle_dir(1) / "proposals.json").read_text())["proposals"][ea]
        frozen = json.loads((HERE / "loop_config.json").read_text())["frozen_params"][ea]
        self.assertNotIn(prop["param"], frozen)


    def test_account_check(self):
        logs = self.tmp / "data" / "logs"
        logs.mkdir(parents=True)
        t = {"data_dir": str(self.tmp / "data"), "allowed_logins": ["5057237545"]}
        self.assertFalse(loop.account_check(t)[0])
        line = "0\t16:14\tNetwork\t'{}': trading has been enabled - {} mode\n"
        (logs / "20261013.log").write_text(line.format("100149667", "netting"), encoding="utf-16")
        ok, msg = loop.account_check(t)
        self.assertFalse(ok)
        self.assertIn("not in tester.allowed_logins", msg)
        (logs / "20261014.log").write_text(line.format("5057237545", "hedging"), encoding="utf-16")
        self.assertTrue(loop.account_check(t)[0])
        self.assertFalse(loop.account_check(dict(t, allowed_logins=[]))[0])
        cfg = json.loads((self.root / "loop_config.json").read_text())
        cfg["tester"]["data_dir"] = t["data_dir"]
        (self.root / "loop_config.json").write_text(json.dumps(cfg))
        (logs / "20261015.log").write_text(line.format("5057237545", "netting"), encoding="utf-16")
        self.run_cli("init", "--ea-dir", str(self.tmp))
        self.run_cli("propose", "--only", "EA1_MACrossover_ATR")
        with self.assertRaises(SystemExit):
            self.run_cli("run")
        # Demo wording is accepted by the check; asserted only, never launched.
        (logs / "20261016.log").write_text(
            "0\t16:14\tNetwork\t'5057237545': trading has been enabled, demo account - hedging mode\n",
            encoding="utf-16")
        self.assertTrue(loop.account_check(t)[0])


if __name__ == "__main__":
    unittest.main()
