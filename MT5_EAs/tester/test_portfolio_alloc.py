"""Offline tests for portfolio_alloc.py.

Run: python -m unittest test_portfolio_alloc   (from MT5_EAs/tester)
"""

import csv
import tempfile
import unittest
from pathlib import Path

import portfolio_alloc as pa


def row(ea, symbol="EURUSD", passed="True", failed="", pf="1.6", dd="10", tpy="80", ho="1.2"):
    return {"ea": ea, "symbol": symbol, "pass": passed, "failed": failed, "oos_pf": pf,
            "oos_max_dd_pct": dd, "oos_trades_per_year": tpy, "holdout_pf": ho}


MAGICS = {"EA1_A": 10001, "EA2_B": 10002, "EA3_C": 10003}


class MagicTests(unittest.TestCase):
    def test_reads_magic_and_skips_guard(self):
        with tempfile.TemporaryDirectory() as d:
            Path(d, "EA1_A.mq5").write_text('trade.SetExpertMagicNumber(10001);\n', encoding="utf-8")
            Path(d, "EA00_PortfolioGuard.mq5").write_text("no magic here\n", encoding="utf-8")
            self.assertEqual(pa.read_magics(d), {"EA1_A": 10001})

    def test_missing_magic_is_an_error(self):
        with tempfile.TemporaryDirectory() as d:
            Path(d, "EA9_X.mq5").write_text("int x;\n", encoding="utf-8")
            with self.assertRaises(ValueError):
                pa.read_magics(d)


class AllocateTests(unittest.TestCase):
    def test_failing_eas_get_no_capital(self):
        rows = [row("EA1_A"), row("EA2_B", passed="False", failed="pf;dd")]
        out = {r["ea"]: r for r in pa.allocate(rows, MAGICS)}
        self.assertEqual(out["EA2_B"]["status"], "inactive")
        self.assertEqual(out["EA2_B"]["risk_mult"], "0.00")
        self.assertIn("pf;dd", out["EA2_B"]["reason"])
        self.assertEqual(out["EA1_A"]["status"], "active")

    def test_equal_scores_give_multiplier_one(self):
        rows = [row("EA1_A"), row("EA2_B")]
        out = pa.allocate(rows, MAGICS)
        self.assertEqual([r["risk_mult"] for r in out], ["1.00", "1.00"])

    def test_better_pf_and_lower_dd_get_more_risk(self):
        rows = [row("EA1_A", pf="2.0", dd="5"), row("EA2_B", pf="1.4", dd="15")]
        out = {r["ea"]: float(r["risk_mult"]) for r in pa.allocate(rows, MAGICS)}
        self.assertGreater(out["EA1_A"], out["EA2_B"])

    def test_multiplier_is_capped(self):
        rows = [row("EA1_A", pf="3.0", dd="1"), row("EA2_B", pf="1.3", dd="25")]
        out = {r["ea"]: float(r["risk_mult"]) for r in pa.allocate(rows, MAGICS, max_mult=1.5)}
        self.assertLessEqual(out["EA1_A"], 1.5)

    def test_unknown_ea_is_inactive(self):
        out = pa.allocate([row("EA99_Z")], MAGICS)
        self.assertEqual(out[0]["status"], "inactive")
        self.assertIn("magic", out[0]["reason"])

    def test_trade_frequency_floor(self):
        out = pa.allocate([row("EA1_A", tpy="20")], MAGICS, min_trades_per_year=50)
        self.assertEqual(out[0]["status"], "inactive")

    def test_optional_holdout_gate(self):
        rows = [row("EA1_A", ho="0.9"), row("EA2_B", ho="1.1")]
        out = {r["ea"]: r["status"] for r in pa.allocate(rows, MAGICS, require_holdout_pf=1.0)}
        self.assertEqual(out, {"EA1_A": "inactive", "EA2_B": "active"})

    def test_no_active_rows_writes_no_weights(self):
        out = pa.allocate([row("EA1_A", passed="False")], MAGICS)
        self.assertEqual(out[0]["status"], "inactive")


class WriteTests(unittest.TestCase):
    def test_round_trip_matches_mql_columns(self):
        out = pa.allocate([row("EA1_A"), row("EA2_B", passed="False")], MAGICS)
        with tempfile.TemporaryDirectory() as d:
            path = Path(d, "sub", "portfolio_allocation.csv")
            pa.write_allocation(out, path)
            with open(path, newline="", encoding="utf-8") as f:
                rows = list(csv.reader(f))
        self.assertEqual(rows[0], pa.HEADER)
        # Include/Portfolio.mqh reads columns: ea, magic, symbol, risk_mult, weight, status
        self.assertEqual(rows[0][:6], ["ea", "magic", "symbol", "risk_mult", "weight", "status"])
        self.assertEqual(rows[1][5], "active")
        self.assertEqual(rows[2][5], "inactive")


if __name__ == "__main__":
    unittest.main()
