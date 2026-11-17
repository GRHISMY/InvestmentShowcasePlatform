"""The command boundary preserves comparability and does not invent missing metrics."""
import importlib.util
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest

spec = importlib.util.spec_from_file_location("native_performance", Path(__file__).with_name("run_native_performance.py"))
performance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(performance)


class NativePerformanceTests(unittest.TestCase):
    def test_cli_copies_selected_harness_and_defaults_to_current_tests(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            source = root / "frozen-source"
            app = source / "ios/CompanyLens"
            original_files = {
                "App/Report.swift": b"unchanged frozen report app\n",
                "Core/Reader.swift": b"unchanged frozen reader\n",
                "Study/research.json": b"complete-formal-study",
                "CompanyLens.xcodeproj/project.pbxproj": b"unchanged frozen project\n",
                "UITests/StudyReadingUITests.swift": b"original frozen tests\n",
            }
            for name, contents in original_files.items():
                path = app / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(contents)
            manifest = root / "content-manifest.json"
            manifest.write_text(json.dumps({"baseline_commit": "frozen-commit", "study_files": {
                "research.json": {"sha256": hashlib.sha256(b"complete-formal-study").hexdigest(), "bytes": 21}
            }}))
            legacy = root / "legacy-StudyReadingUITests.swift"
            legacy.write_bytes(b"explicit legacy button performance harness\n")
            current = Path(__file__).parents[1] / "UITests/StudyReadingUITests.swift"
            self.assertNotEqual(legacy.read_bytes(), current.read_bytes())

            # Substitute only the external Xcode/device commands; execute the real CLI and file copy.
            bin_dir = root / "bin"
            bin_dir.mkdir()
            commands = {
                "xcrun": 'print("test-iphone physical iPhone connected")\n',
                "xcodebuild": textwrap.dedent('''\
                    import pathlib, plistlib, sys
                    if "build-for-testing" in sys.argv:
                        derived = pathlib.Path(sys.argv[sys.argv.index("-derivedDataPath") + 1])
                        products = derived / "Build/Products"
                        products.mkdir(parents=True)
                        with (products / "CompanyLens.xctestrun").open("wb") as stream:
                            plistlib.dump({"CompanyLensUITests": {}}, stream)
                    elif "-version" in sys.argv:
                        print("Xcode fixture")
                    elif "test-without-building" not in sys.argv:
                        sys.exit("Unexpected Xcode command")
                    '''),
            }
            for name, program in commands.items():
                path = bin_dir / name
                path.write_text("#!" + sys.executable + "\n" + program)
                path.chmod(0o755)
            env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ["PATH"])
            for name, selected, options in [("legacy", legacy, ["--harness-tests", str(legacy)]),
                                             ("current", current, [])]:
                with self.subTest(harness=name):
                    output = root / name
                    result = subprocess.run([sys.executable, str(Path(__file__).with_name("run_native_performance.py")),
                        "--source", str(source), "--content-manifest", str(manifest), "--device", "test-iphone",
                        "--configuration", "Debug", "--output", str(output), *options],
                        env=env, text=True, capture_output=True)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    copied = output / "harness-source/ios/CompanyLens"
                    self.assertEqual((copied / "UITests/StudyReadingUITests.swift").read_bytes(), selected.read_bytes())
                    metadata = json.loads((output / "run-manifest.json").read_text())
                    self.assertEqual(metadata["harness_tests_source"], str(selected.resolve()))
                    self.assertEqual(metadata["harness_sha256"], hashlib.sha256(selected.read_bytes()).hexdigest())
                    for path, contents in original_files.items():
                        self.assertEqual((app / path).read_bytes(), contents)
                        if not path.startswith("UITests/"):
                            self.assertEqual((copied / path).read_bytes(), contents)

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
