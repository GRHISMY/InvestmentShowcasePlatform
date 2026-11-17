"""The command boundary preserves comparability and does not invent missing metrics."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("native_performance", Path(__file__).with_name("run_native_performance.py"))
performance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(performance)


class NativePerformanceTests(unittest.TestCase):
    def test_summary_uses_nearest_rank_and_keeps_metric_identity(self):
        samples = [
            {"scenario": "warm-diagram-to-report", "elapsed_ms": value,
             "metric_kind": "xcui-tap-to-accessibility-ready-upper-bound"}
            for value in [4, 1, 100, 2, 3]
        ]
        summary = performance.summarize(samples)
        result = summary["warm-diagram-to-report"]
        self.assertEqual(result["n"], 5)
        self.assertEqual(result["p50_ms"], 3)
        self.assertEqual(result["p95_ms"], 100)
        self.assertEqual(result["metric_kind"], "xcui-tap-to-accessibility-ready-upper-bound")
        self.assertNotIn("hitch_ratio", result)
        self.assertNotIn("passed", result)

    def test_changed_or_missing_study_bytes_refuse_baseline_comparison(self):
        with tempfile.TemporaryDirectory() as root:
            study = Path(root)
            (study / "research.json").write_bytes(b"complete-formal-study")
            manifest = performance.content_manifest(study)
            performance.verify_content(study, manifest)
            (study / "research.json").write_bytes(b"shortened")
            with self.assertRaisesRegex(ValueError, "content differs"):
                performance.verify_content(study, manifest)


if __name__ == "__main__":
    unittest.main()
