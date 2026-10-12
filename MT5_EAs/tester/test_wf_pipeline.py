"""Offline tests for wf_pipeline.py using synthetic MT5 reports.

Run: python -m unittest test_wf_pipeline   (from MT5_EAs/tester)
"""

import json
import tempfile
import unittest
from pathlib import Path

import wf_pipeline as wf

HERE = Path(__file__).resolve().parent

XML_HEAD = ('<?xml version="1.0"?>\n<Workbook xmlns="urn:schemas-microsoft-com:office:spreadsheet" '
            'xmlns:ss="urn:schemas-microsoft-com:office:spreadsheet">\n'
            '<Worksheet ss:Name="Tester Optimizator Results"><Table>\n')
COLUMNS = ["Pass", "Result", "Profit", "Expected Payoff", "Profit Factor", "Recovery Factor",
           "Sharpe Ratio", "Custom", "Equity DD %", "Trades"]


def opt_xml(param_names, passes):
    def row(values, typ):
        cells = "".join(f'<Cell><Data ss:Type="{typ}">{v}</Data></Cell>' for v in values)
        return f"<Row>{cells}</Row>\n"
    body = row(COLUMNS + param_names, "String")
    for p in passes:
        body += row(p, "Number")
    return XML_HEAD + body + "</Table></Worksheet></Workbook>\n"


def backtest_html(net, gp, gl, pf, dd_pct, trades, win_pct, sharpe=1.1):
    rows = [
        ("Total Net Profit:", f"{net:,.2f}".replace(",", " ")),
        ("Gross Profit:", f"{gp:,.2f}".replace(",", " ")),
        ("Gross Loss:", f"{gl:,.2f}".replace(",", " ")),
        ("Profit Factor:", f"{pf:.2f}"),
        ("Expected Payoff:", f"{net / max(trades, 1):.2f}"),
        ("Recovery Factor:", "2.10"),
        ("Sharpe Ratio:", f"{sharpe:.2f}"),
        ("Equity Drawdown Maximal:", f"1 234.56 ({dd_pct + 1:.2f}%)"),
        ("Equity Drawdown Relative:", f"{dd_pct:.2f}% (1 100.00)"),
        ("Total Trades:", str(trades)),
        ("Profit Trades (% of total):", f"{round(trades * win_pct / 100)} ({win_pct:.2f}%)"),
    ]
    tds = "".join(f'<tr><td nowrap colspan=3 align=right>{k}</td>'
                  f'<td nowrap align=right><b>{v}</b></td></tr>\n' for k, v in rows)
    return f"<html><body><table>{tds}</table></body></html>"


class ParserTests(unittest.TestCase):
    def test_html_utf16(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "r.htm"
            p.write_text(backtest_html(1523.4, 5000, -3476.6, 1.44, 8.75, 260, 47.5), encoding="utf-16")
            m = wf.parse_backtest_html(p)
        self.assertAlmostEqual(m["net_profit"], 1523.4)
        self.assertAlmostEqual(m["gross_loss"], -3476.6)
        self.assertAlmostEqual(m["profit_factor"], 1.44)
        self.assertAlmostEqual(m["equity_dd_rel"], 8.75)
        self.assertAlmostEqual(m["equity_dd_max_pct"], 9.75)
        self.assertEqual(m["total_trades"], 260)
        self.assertAlmostEqual(m["win_rate"], 47.5)

    def test_optimization_xml(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "r.xml"
            p.write_text(opt_xml(["A", "B"], [[1, 10.5, 900, 3, 1.4, 2, 1, 0, 9, 200, 10, 1.5]]),
                         encoding="utf-16")
            rows = wf.parse_optimization_xml(p)
        self.assertEqual(rows[0]["Profit Factor"], 1.4)
        self.assertEqual(rows[0]["B"], 1.5)

    def test_windows(self):
        w = wf.build_windows({"start": "2016-01-01", "end": "2026-01-01", "is_months": 48,
                              "oos_months": 12, "step_months": 12, "holdout_split": 0.7})
        self.assertEqual(len(w), 7)
        self.assertEqual(str(w[0][2]), "2019-12-31")
        self.assertEqual(str(w[-1][3]), "2023-01-01")

    def test_plateau_prefers_stable_region(self):
        rng = {"A": [10, 5, 40]}
        sel = {"method": "plateau", "top_k": 5, "min_is_trades_per_year": 0,
               "max_is_profit_factor": 5, "max_is_equity_dd_pct": 50}
        def p(a, result):
            return {"A": a, "Result": result, "Trades": 100, "Profit Factor": 1.5,
                    "Equity DD %": 10, "Profit": 100}
        # A=40 is an isolated spike; A=20 sits in a broad good region.
        passes = [p(10, 5), p(15, 8), p(20, 9), p(25, 8), p(30, 7), p(35, 1), p(40, 12)]
        best, _ = wf.select_params(passes, rng, sel, 4)
        self.assertEqual(best["A"], 20)
        sel["method"] = "top"
        best, _ = wf.select_params(passes, rng, sel, 4)
        self.assertEqual(best["A"], 40)


class EndToEndTest(unittest.TestCase):
    def test_generate_select_report(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            plan = json.loads((HERE / "wf_plan.json").read_text())
            plan["settings"].update({"data_dir": str(d / "data"), "work_dir": str(d / "work"),
                                     "ea_source_dir": str(HERE.parent)})
            plan["eas"] = {k: plan["eas"][k] for k in ("EA1_MACrossover_ATR", "EA7_SuperTrend")}
            plan_path = d / "plan.json"
            plan_path.write_text(json.dumps(plan))
            wf.main(["generate", "--plan", str(plan_path)])
            p = wf.load_plan(plan_path)

            for ea, cfg, sym, tf, (win, *_rest) in wf.iter_jobs(p):
                names = list(cfg["optimize"])
                passes = []
                for i in range(30):
                    vals = [cfg["optimize"][n][0] + (i % 3) * cfg["optimize"][n][1] for n in names]
                    passes.append([i, 50 + i, 1000 + i, 5, 1.6, 2, 1.2, 0, 12, 400] + vals)
                rel = wf.report_rel(p, ea, sym, tf, win, "IS").replace("\\", "/")
                f = d / "data" / (rel + ".xml")
                f.parent.mkdir(parents=True, exist_ok=True)
                f.write_text(opt_xml(names, passes), encoding="utf-16")
            wf.main(["select", "--plan", str(plan_path)])
            oos_inis = list((d / "work" / "oos").glob("*.ini"))
            self.assertEqual(len(oos_inis), 14)
            text = oos_inis[0].read_text(encoding="utf-16")
            self.assertIn("Optimization=0", text)
            self.assertIn("Model=4", text)
            self.assertNotRegex(text, r"(?m)\|\|Y$")

            # EA1 is consistently good OOS, EA7 falls apart.
            for ea, cfg, sym, tf, (win, *_rest) in wf.iter_jobs(p):
                good = ea == "EA1_MACrossover_ATR"
                html_text = (backtest_html(800, 2600, -1800, 1.44, 9, 80, 48, 1.0) if good
                             else backtest_html(-300, 1200, -1500, 0.8, 25, 30, 38, -0.2))
                rel = wf.report_rel(p, ea, sym, tf, win, "OOS").replace("\\", "/")
                f = d / "data" / (rel + ".htm")
                f.parent.mkdir(parents=True, exist_ok=True)
                f.write_text(html_text, encoding="utf-16")
            wf.main(["report", "--plan", str(plan_path)])
            rows = wf.collect_results(p)
            self.assertEqual(rows[0]["ea"], "EA1_MACrossover_ATR")
            self.assertTrue(rows[0]["agg"]["pass"], rows[0]["agg"]["failed"])
            self.assertFalse(rows[1]["agg"]["pass"])
            self.assertTrue((d / "work" / "leaderboard.md").exists())


if __name__ == "__main__":
    unittest.main()
