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
    def test_recording_attaches_exact_app_pid_and_records_verified_target(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result, output = self.recording_cli(root)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            metadata = json.loads((output / "run-manifest.json").read_text())
            self.assertEqual(metadata.get("trace_target_pid"), 1403)
            self.assertEqual(metadata.get("trace_status"), "verified-app-target")
            self.assertIn("Attaching to: 看懂公司 (1403)", (output / "instruments.log").read_text())
            self.assertEqual(metadata.get("observed_runner_conditions"), [
                {"thermal_state": "nominal", "scope": "test-runner-and-system-state-not-app-presented-frame"}])

    def test_recording_rejects_wrong_or_missing_instruments_target_even_when_ui_passes(self):
        for target in ["CompanyLensUITests-Runner (1398)", "CompanyLens (9999)", "unknown target"]:
            with self.subTest(target=target), tempfile.TemporaryDirectory() as directory:
                result, output = self.recording_cli(Path(directory), recorded_target=target)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                metadata = json.loads((output / "run-manifest.json").read_text())
                self.assertEqual(metadata["test_exit_code"], 0)
                self.assertEqual(metadata["trace_status"], "invalid-or-missing-app-target")

    def test_recording_preserves_ui_result_when_exact_app_process_cannot_be_resolved(self):
        app = {"executable": "file:///private/CompanyLens.app/CompanyLens", "processIdentifier": 1403}
        runner = {"executable": "file:///private/CompanyLensUITests-Runner.app/CompanyLensUITests-Runner", "processIdentifier": 1398}
        for processes in [[runner], [app, dict(app, processIdentifier=1404)], [dict(app, processIdentifier=None)]]:
            with self.subTest(processes=processes), tempfile.TemporaryDirectory() as directory:
                result, output = self.recording_cli(Path(directory), processes=processes)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                metadata = json.loads((output / "run-manifest.json").read_text())
                self.assertEqual(metadata.get("test_exit_code"), 0)
                self.assertEqual(metadata.get("trace_status"), "unresolvable-app-target")
                self.assertFalse((output / "instruments.log").exists())

    def test_recording_finalization_timeout_preserves_ui_pass_and_reaps_profiler(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result, output = self.recording_cli(root, trace_hangs=True,
                options=["--trace-seconds", "1", "--trace-finalize-seconds", "0.1"])
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            metadata = json.loads((output / "run-manifest.json").read_text())
            self.assertEqual(metadata.get("test_exit_code"), 0)
            self.assertEqual(metadata.get("trace_status"), "finalization-timeout")
            self.assertEqual(metadata.get("trace_exit_code"), -9)
            pid = int((output / "native-report.trace/profiler.pid").read_text())
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)

    def test_recording_rejects_unreadable_trace_even_after_matching_target_and_ui_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            result, output = self.recording_cli(Path(directory), trace_export_fails=True)
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            metadata = json.loads((output / "run-manifest.json").read_text())
            self.assertEqual(metadata.get("test_exit_code"), 0)
            self.assertEqual(metadata.get("trace_status"), "unreadable-trace-data")

    def test_recording_can_launch_exact_bundle_before_harness_activates_it(self):
        with tempfile.TemporaryDirectory() as directory:
            result, output = self.recording_cli(Path(directory), options=["--prelaunch-app"])
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            metadata = json.loads((output / "run-manifest.json").read_text())
            self.assertEqual(metadata.get("app_start_method"), "devicectl-prelaunch-existing-process")
            self.assertEqual(metadata.get("trace_target_pid"), 1403)
            self.assertEqual(metadata.get("trace_status"), "verified-app-target")

    def test_recording_allows_configured_trace_limit_instead_of_interrupting_at_ui_end(self):
        with tempfile.TemporaryDirectory() as directory:
            result, output = self.recording_cli(Path(directory), trace_natural_seconds=1,
                options=["--trace-seconds", "2", "--trace-finalize-seconds", "0.1"])
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            metadata = json.loads((output / "run-manifest.json").read_text())
            self.assertEqual(metadata.get("trace_exit_code"), 0)

    def test_recording_rejects_saved_trace_with_another_target_pid(self):
        with tempfile.TemporaryDirectory() as directory:
            result, output = self.recording_cli(Path(directory), saved_target_pid=1398)
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            metadata = json.loads((output / "run-manifest.json").read_text())
            self.assertEqual(metadata.get("test_exit_code"), 0)
            self.assertEqual(metadata.get("trace_status"), "invalid-saved-trace-target")

    def test_recording_keeps_an_explicit_supplemental_instruments_template_in_provenance(self):
        with tempfile.TemporaryDirectory() as directory:
            result, output = self.recording_cli(Path(directory), options=["--trace-template", "Explicit legacy template",
                                                                         "--trace-instrument", "os_signpost"])
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            metadata = json.loads((output / "run-manifest.json").read_text())
            self.assertEqual(metadata.get("trace_template"), "Explicit legacy template")
            self.assertEqual(metadata.get("trace_instruments"), ["Time Profiler", "os_signpost"])

    def test_recording_retries_transient_exact_pid_visibility_without_falling_back_to_name(self):
        with tempfile.TemporaryDirectory() as directory:
            result, output = self.recording_cli(Path(directory), startup_failures=1)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            metadata = json.loads((output / "run-manifest.json").read_text())
            self.assertEqual(metadata.get("trace_start_attempts"), 2)
            self.assertEqual(metadata.get("trace_target_pid"), 1403)
            self.assertEqual(metadata.get("trace_status"), "verified-app-target")

    def test_cli_preserves_explicit_diagnostic_source_provenance_separately_from_harness_changes(self):
        overlay = {"schema": "companylens-external-measurement-overlay/v1",
                   "diagnostic_source_differs_from_normal_production": True, "patch_sha256": "explicit-probe-patch"}
        with tempfile.TemporaryDirectory() as directory:
            result, output = self.recording_cli(Path(directory), source_overlay=overlay)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            metadata = json.loads((output / "run-manifest.json").read_text())
            self.assertEqual(metadata.get("source_diagnostic_overlay"), overlay)
            self.assertFalse(metadata["production_behavior_changes_by_harness"])

    def test_cli_explicitly_installs_the_built_configuration_and_records_its_device_path(self):
        for configuration in ["Debug", "Release"]:
            with self.subTest(configuration=configuration), tempfile.TemporaryDirectory() as directory:
                result, output = self.recording_cli(Path(directory), configuration=configuration)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                metadata = json.loads((output / "run-manifest.json").read_text())
                self.assertEqual(metadata.get("installed_app", {}).get("installation_url"), "file:///private/CompanyLens.app/")
                self.assertEqual(metadata.get("installed_app", {}).get("configuration"), configuration)
                self.assertTrue((output / "app-install-before-tests.json").is_file())
                built = json.loads((output / "built-app-manifest.json").read_text())
                self.assertEqual(built["CompanyLens"]["sha256"], hashlib.sha256(("fixture compiled " + configuration + " app").encode()).hexdigest())

    def test_recording_rejects_a_replacement_app_process_before_the_measured_interaction(self):
        with tempfile.TemporaryDirectory() as directory:
            result, output = self.recording_cli(Path(directory), changed_pid_after_ready=True, options=["--prelaunch-app"])
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            metadata = json.loads((output / "run-manifest.json").read_text())
            self.assertEqual(metadata.get("trace_status"), "app-process-changed-before-measurement")
            self.assertEqual(metadata.get("app_pid_at_measurement_ready"), 1404)
            self.assertEqual(metadata.get("test_exit_code"), 0)

    def test_first_frame_scope_freezes_and_applies_explicit_signpost_recording_options(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            selected = root / "probe-options.json"
            selected.write_text(json.dumps({"os_signpost": {"dynamicTracingEnabledSubsystems": ["com.companylens.measurement"],
                                                           "recordAllProcessesInSingleProcessMode": False}}))
            result, output = self.recording_cli(root, options=["--scenario", "first-frame", "--trace-recording-options", str(selected)])
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            metadata = json.loads((output / "run-manifest.json").read_text())
            self.assertEqual(metadata["scenario"], "first-frame")
            self.assertEqual(metadata.get("trace_recording_options_sha256"), hashlib.sha256(selected.read_bytes()).hexdigest())
            self.assertEqual((output / "trace-recording-options.json").read_bytes(), selected.read_bytes())
            with (output / "DerivedData/Build/Products/NativePerformance.xctestrun").open("rb") as stream:
                import plistlib
                plan = plistlib.load(stream)
            self.assertEqual(plan["CompanyLensUITests"]["EnvironmentVariables"]["COMPANYLENS_PERF_FIRST_REPORT_ONLY"], "1")

    def test_manual_gui_recording_preserves_exact_installed_target_without_claiming_a_trace(self):
        with tempfile.TemporaryDirectory() as directory:
            result, output = self.recording_cli(Path(directory), options=["--prelaunch-app", "--manual-gui-record"])
            self.assertNotEqual(result.returncode, 0, "An external GUI trace still requires independent validation")
            metadata = json.loads((output / "run-manifest.json").read_text())
            self.assertEqual(metadata["test_exit_code"], 0)
            self.assertEqual(metadata["trace_status"], "manual-gui-evidence-required")
            self.assertEqual(metadata["trace_target_pid"], 1403)
            self.assertEqual(metadata["app_pid_at_measurement_ready"], 1403)
            self.assertTrue((output / "gui-record-target.json").is_file())
            self.assertFalse((output / "instruments.log").exists())
            self.assertFalse((output / "native-report.trace").exists())
            import plistlib
            with (output / "DerivedData/Build/Products/NativePerformance.xctestrun").open("rb") as stream:
                plan = plistlib.load(stream)
            self.assertEqual(plan["CompanyLensUITests"]["EnvironmentVariables"]["COMPANYLENS_PERF_TRACE_WAIT_SECONDS"], "60")

    def recording_cli(self, root, processes=None, recorded_target=None, trace_hangs=False, trace_export_fails=False,
                      trace_natural_seconds=.2, saved_target_pid=1403, startup_failures=0, changed_pid_after_ready=False,
                      source_overlay=None, configuration="Debug", options=None):
        source = root / "source"
        study = source / "ios/CompanyLens/Study"
        study.mkdir(parents=True)
        (study / "research.json").write_bytes(b"complete study")
        tests = source / "ios/CompanyLens/UITests/StudyReadingUITests.swift"
        tests.parent.mkdir()
        tests.write_text("fixture harness; COMPANYLENS_PERF_FIRST_REPORT_ONLY COMPANYLENS_PERF_TRACE_WAIT_SECONDS\n")
        if source_overlay is not None:
            (source / "diagnostic-overlay.json").write_text(json.dumps(source_overlay))
        manifest = root / "content.json"
        manifest.write_text(json.dumps({"study_files": performance.content_manifest(study)}))
        bin_dir = root / "bin"
        bin_dir.mkdir()
        processes = processes if processes is not None else [
            {"executable": "file:///private/Runner.app/CompanyLensUITests-Runner", "processIdentifier": 1398},
            {"executable": "file:///private/CompanyLens.app/CompanyLens", "processIdentifier": 1403}]
        device_program = textwrap.dedent('''\
            import json, os, pathlib, signal, sys, time
            if "devices" in sys.argv:
                print("test-iphone physical iPhone connected")
            elif "install" in sys.argv:
                app = pathlib.Path(sys.argv[sys.argv.index("--device") + 2])
                assert app.name == "CompanyLens.app" and (app / "CompanyLens").is_file()
                pathlib.Path(sys.argv[sys.argv.index("--json-output") + 1]).write_text(json.dumps({"result":{"installedApplications":[{"bundleID":"com.companylens.prototype","installationURL":"file:///private/CompanyLens.app/"}]}}))
            elif "processes" in sys.argv:
                processes = PROCESSES
                counter = pathlib.Path(__file__).parent / "process-queries.count"
                count = int(counter.read_text()) if counter.exists() else 0
                counter.write_text(str(count + 1))
                if CHANGED_PID_AFTER_READY and count > 0:
                    processes = [dict(p, processIdentifier=1404) if p.get("processIdentifier") == 1403 else p for p in processes]
                print(json.dumps({"result": {"runningProcesses": processes}}))
            elif "launch" in sys.argv:
                assert "com.companylens.prototype" in sys.argv
                assert "--terminate-existing" in sys.argv
            elif "record" in sys.argv:
                target = sys.argv[sys.argv.index("--attach") + 1]
                output = pathlib.Path(sys.argv[sys.argv.index("--output") + 1])
                counter = output.parent / "attempts.count"
                attempts = int(counter.read_text()) if counter.exists() else 0
                counter.write_text(str(attempts + 1))
                if attempts < STARTUP_FAILURES:
                    print("Cannot find process for provided pid: " + target, flush=True)
                    sys.exit(21)
                actual = RECORDED_TARGET or ("看懂公司 (1403)" if target == "1403" else "CompanyLensUITests-Runner (1398)")
                print("Starting recording. Attaching to: " + actual + ". Time limit: 240.0 s", flush=True)
                output.mkdir()
                (output / "profiler.pid").write_text(str(os.getpid()))
                if TRACE_HANGS:
                    signal.signal(signal.SIGINT, signal.SIG_IGN)
                    time.sleep(120)
                time.sleep(TRACE_NATURAL_SECONDS)
            elif "export" in sys.argv:
                if TRACE_EXPORT_FAILS:
                    sys.exit("Export failed: Trace is malformed; instrument run data is missing")
                pathlib.Path(sys.argv[sys.argv.index("--output") + 1]).write_text('<trace-toc><run number="1"><info><target><process pid="SAVED_TARGET_PID"/></target></info><processes><process pid="SAVED_TARGET_PID" path="/private/CompanyLens.app/CompanyLens"/></processes><data><table schema="time-profile"/></data></run></trace-toc>')
            else:
                sys.exit("Unexpected device command")
            ''').replace("PROCESSES", repr(processes)).replace("RECORDED_TARGET", repr(recorded_target)).replace("TRACE_HANGS", repr(trace_hangs)).replace("TRACE_EXPORT_FAILS", repr(trace_export_fails)).replace("TRACE_NATURAL_SECONDS", repr(trace_natural_seconds)).replace("SAVED_TARGET_PID", str(saved_target_pid)).replace("STARTUP_FAILURES", str(startup_failures)).replace("CHANGED_PID_AFTER_READY", repr(changed_pid_after_ready))
        build_program = textwrap.dedent('''\
            import pathlib, plistlib, shutil, sys, time
            if "build-for-testing" in sys.argv:
                products = pathlib.Path(sys.argv[sys.argv.index("-derivedDataPath") + 1]) / "Build/Products"
                products.mkdir(parents=True)
                with (products / "CompanyLens.xctestrun").open("wb") as stream:
                    plistlib.dump({"CompanyLensUITests": {}}, stream)
                configuration = sys.argv[sys.argv.index("-configuration") + 1]
                app = products / (configuration + "-iphoneos/CompanyLens.app")
                app.mkdir(parents=True)
                (app / "CompanyLens").write_bytes(("fixture compiled " + configuration + " app").encode())
                with (app / "Info.plist").open("wb") as stream:
                    plistlib.dump({"CFBundleIdentifier":"com.companylens.prototype","CFBundleExecutable":"CompanyLens"}, stream)
                shutil.copytree(pathlib.Path(sys.argv[sys.argv.index("-project") + 1]).parent / "Study", app / "Study")
            elif "-version" in sys.argv:
                print("Xcode fixture")
            elif "test-without-building" in sys.argv:
                print('COMPANYLENS_PERF_CONDITIONS {"thermal_state":"nominal","scope":"test-runner-and-system-state-not-app-presented-frame"}', flush=True)
                print("COMPANYLENS_PERF_PRELAUNCH_READY", flush=True)
                print("COMPANYLENS_PERF_TRACE_READY", flush=True)
                time.sleep(1.2)
            else:
                sys.exit("Unexpected Xcode command")
            ''')
        for name, program in {"xcrun": device_program, "xcodebuild": build_program}.items():
            path = bin_dir / name
            path.write_text("#!" + sys.executable + "\n" + program)
            path.chmod(0o755)
        output = root / "evidence"
        result = subprocess.run([sys.executable, str(Path(__file__).with_name("run_native_performance.py")),
            "--source", str(source), "--content-manifest", str(manifest), "--harness-tests", str(tests),
            "--device", "test-iphone", "--configuration", configuration, "--output", str(output), "--record", *(options or [])],
            env=dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ["PATH"]), text=True, capture_output=True)
        return result, output

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
                "xcrun": textwrap.dedent('''\
                    import json, pathlib, sys
                    if "install" in sys.argv:
                        pathlib.Path(sys.argv[sys.argv.index("--json-output") + 1]).write_text(json.dumps({"result":{"installedApplications":[{"bundleID":"com.companylens.prototype","installationURL":"file:///private/CompanyLens.app/"}]}}))
                    else:
                        print("test-iphone physical iPhone connected")
                    '''),
                "xcodebuild": textwrap.dedent('''\
                    import pathlib, plistlib, shutil, sys
                    if "build-for-testing" in sys.argv:
                        derived = pathlib.Path(sys.argv[sys.argv.index("-derivedDataPath") + 1])
                        products = derived / "Build/Products"
                        products.mkdir(parents=True)
                        with (products / "CompanyLens.xctestrun").open("wb") as stream:
                            plistlib.dump({"CompanyLensUITests": {}}, stream)
                        app = products / "Debug-iphoneos/CompanyLens.app"
                        app.mkdir(parents=True)
                        (app / "CompanyLens").write_bytes(b"fixture compiled Debug app")
                        with (app / "Info.plist").open("wb") as stream:
                            plistlib.dump({"CFBundleIdentifier":"com.companylens.prototype","CFBundleExecutable":"CompanyLens"}, stream)
                        shutil.copytree(pathlib.Path(sys.argv[sys.argv.index("-project") + 1]).parent / "Study", app / "Study")
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
