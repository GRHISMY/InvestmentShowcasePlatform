#!/usr/bin/env python3
"""Opt-in native XCUI performance sampling; raw evidence stays outside the repository."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import shutil
import subprocess
import sys
import os
import plistlib
import re
import time
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from urllib.parse import unquote, urlparse


METRIC_KIND = "xcui-tap-to-accessibility-ready-upper-bound"


def summarize(samples):
    grouped = {}
    for sample in samples:
        if sample.get("metric_kind") != METRIC_KIND or "elapsed_ms" not in sample:
            continue
        grouped.setdefault(sample["scenario"], []).append(float(sample["elapsed_ms"]))
    result = {}
    for scenario, values in grouped.items():
        values.sort()
        def percentile(fraction):
            return values[max(0, math.ceil(len(values) * fraction) - 1)]
        result[scenario] = {"n": len(values), "p50_ms": percentile(.5), "p95_ms": percentile(.95),
                            "p99_ms": percentile(.99), "max_ms": max(values), "metric_kind": METRIC_KIND}
    return result


def content_manifest(study):
    return {str(p.relative_to(study)): {"sha256": hashlib.sha256(p.read_bytes()).hexdigest(),
                                       "bytes": p.stat().st_size}
            for p in sorted(study.rglob("*")) if p.is_file()}


def verify_content(study, expected):
    if content_manifest(study) != expected:
        raise ValueError("Formal study content differs from frozen baseline")


def samples_from_log(path):
    result = []
    for line in path.read_text(errors="replace").splitlines():
        marker = "COMPANYLENS_PERF_SAMPLE "
        if marker in line:
            result.append(json.loads(line.split(marker, 1)[1]))
    return result


def run_logged(command, log, env):
    with log.open("w") as stream:
        subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT, env=env, check=True)


def app_process(device, env):
    payload = subprocess.check_output(["xcrun", "devicectl", "-q", "device", "info", "processes", "--device", device,
        "--search", "CompanyLens", "--json-output", "-"], env=env, text=True)
    processes = json.loads(payload).get("result", {}).get("runningProcesses", [])
    matches = [process for process in processes
               if isinstance(process.get("executable"), str)
               and Path(unquote(urlparse(process["executable"]).path)).parts[-2:] == ("CompanyLens.app", "CompanyLens")]
    if len(matches) != 1:
        raise RuntimeError("Expected exactly one running CompanyLens.app/CompanyLens executable; found " + str(len(matches)))
    process = matches[0]
    if type(process.get("processIdentifier")) is not int or process["processIdentifier"] <= 0:
        raise RuntimeError("CompanyLens app process has no valid PID")
    return process


def verified_trace_target(log, pid):
    targets = re.findall(r"Attaching to: (.+?) \((\d+)\)\.", log)
    # Instruments uses CFBundleDisplayName (localized), not necessarily the executable basename.
    return len(targets) == 1 and int(targets[0][1]) == pid and "Runner" not in targets[0][0]


def install_built_app(app, device, configuration, expected, output, phase, env):
    with (app / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("CFBundleIdentifier") != "com.companylens.prototype" or info.get("CFBundleExecutable") != "CompanyLens":
        raise RuntimeError("Built app identity does not match CompanyLens")
    verify_content(app / "Study", expected)
    built_files = content_manifest(app)
    built_manifest = output / "built-app-manifest.json"
    if built_manifest.exists():
        if json.loads(built_manifest.read_text()) != built_files:
            raise RuntimeError("Built app bytes changed during the run")
    else:
        built_manifest.write_text(json.dumps(built_files, indent=2) + "\n")
    result = output / ("app-install-" + phase + ".json")
    run_logged(["xcrun", "devicectl", "-q", "device", "install", "app", "--device", device, str(app),
                "--json-output", str(result)], output / ("app-install-" + phase + ".log"), env)
    installed = [item for item in json.loads(result.read_text()).get("result", {}).get("installedApplications", [])
                 if item.get("bundleID") == "com.companylens.prototype"]
    if len(installed) != 1 or Path(unquote(urlparse(installed[0].get("installationURL", "")).path)).name != "CompanyLens.app":
        raise RuntimeError("Device did not confirm the exact CompanyLens installation")
    return {"configuration": configuration, "local_app_path": str(app),
            "installation_url": installed[0]["installationURL"], "phase": phase,
            "built_app_manifest_sha256": hashlib.sha256(built_manifest.read_bytes()).hexdigest()}


def installed_process_matches(process, installation):
    def normalized(url):
        path = unquote(urlparse(url).path).rstrip("/")
        return path.removeprefix("/private") if path.startswith("/private/var/") else path
    return normalized(process["executable"]) == normalized(installation["installation_url"]) + "/CompanyLens"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True, help="Pristine frozen baseline source root or candidate checkout")
    parser.add_argument("--content-manifest", type=Path, required=True)
    parser.add_argument("--harness-tests", type=Path, default=Path(__file__).parents[1] / "UITests/StudyReadingUITests.swift",
                        help="UI test source compatible with --source; defaults to this tool's current tests")
    parser.add_argument("--device", required=True, help="Physical iPhone UDID (never simulator)")
    parser.add_argument("--configuration", choices=["Debug", "Release"], required=True)
    parser.add_argument("--output", type=Path, required=True, help="New external evidence directory")
    parser.add_argument("--scenario", choices=["journey", "first-frame", "fresh", "warm", "scroll", "jumps", "full"], default="journey")
    parser.add_argument("--repetitions", type=int, default=10)
    parser.add_argument("--scroll-seconds", type=float, default=30)
    parser.add_argument("--trace-seconds", type=int, default=240)
    parser.add_argument("--trace-template", default="Animation Hitches",
                        help="Explicit Instruments template name/path; supplemental templates form a separate comparison cohort")
    parser.add_argument("--trace-instrument", action="append", default=[],
                        help="Additional app-scoped instrument; repeat for matched diagnostic cohorts")
    parser.add_argument("--trace-recording-options", type=Path,
                        help="Explicit instrument options JSON, copied and hashed with the evidence")
    parser.add_argument("--trace-finalize-seconds", type=float, default=300,
                        help="Bounded grace period after stopping Instruments; a timeout invalidates the trace")
    parser.add_argument("--record", action="store_true", help="Attach Animation Hitches and Time Profiler to CompanyLens only; journey scenario")
    parser.add_argument("--prelaunch-app", action="store_true",
                        help="Launch the exact app bundle via devicectl, then let a compatible journey harness activate it")
    args = parser.parse_args()
    if args.repetitions < 1 or args.scroll_seconds <= 0 or args.trace_seconds <= 0 or args.trace_finalize_seconds <= 0:
        parser.error("Positive repetitions and scroll duration required")
    if args.record and args.scenario not in ("journey", "first-frame"):
        parser.error("--record requires --scenario journey or first-frame")
    if args.prelaunch_app and not args.record:
        parser.error("--prelaunch-app requires --record")
    if args.output.exists():
        parser.error("Output must be a new directory; never overwrite prior evidence")
    source = args.source.resolve()
    harness_tests = args.harness_tests.resolve()
    if not harness_tests.is_file():
        parser.error("Harness tests must be an existing UI test source file")
    if args.scenario == "first-frame" and "COMPANYLENS_PERF_FIRST_REPORT_ONLY" not in harness_tests.read_text():
        parser.error("The selected harness does not support the first-report-only protocol")
    if args.trace_recording_options and not args.trace_recording_options.is_file():
        parser.error("Trace recording options must be an existing JSON file")
    if args.output.resolve().is_relative_to(source):
        parser.error("Evidence output must be outside the source tree")
    frozen = json.loads(args.content_manifest.read_text())
    expected = frozen["study_files"]
    verify_content(source / "ios/CompanyLens/Study", expected)
    env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
    # Only query this designated device. Never collect other applications, personal files or all-process traces.
    devices = subprocess.check_output(["xcrun", "devicectl", "list", "devices"], env=env, text=True)
    matching = [line for line in devices.splitlines() if args.device in line]
    if len(matching) != 1 or "physical" not in matching[0] or "connected" not in matching[0] or "iPhone" not in matching[0]:
        parser.error("The selected physical iPhone is not connected")
    args.output.mkdir(parents=True)
    output = args.output.resolve()
    trace_options = None
    if args.trace_recording_options:
        trace_options = output / "trace-recording-options.json"
        shutil.copy2(args.trace_recording_options, trace_options)
    harness = output / "harness-source"
    shutil.copytree(source, harness, ignore=shutil.ignore_patterns(".git", ".build", "Verification", "DerivedData", "__pycache__"))
    # Replace only an already-included test source. App/Core/Study/project stay byte-for-byte unchanged.
    shutil.copy2(harness_tests, harness / "ios/CompanyLens/UITests/StudyReadingUITests.swift")
    verify_content(harness / "ios/CompanyLens/Study", expected)
    project = harness / "ios/CompanyLens/CompanyLens.xcodeproj"
    derived = output / "DerivedData"
    build = ["xcodebuild", "-project", str(project), "-scheme", "CompanyLens", "-configuration", args.configuration,
             "-destination", "id=" + args.device, "-derivedDataPath", str(derived), "-jobs", "2", "-allowProvisioningUpdates", "build-for-testing"]
    print("Building the selected native source plus opt-in test harness; logs remain local.", flush=True)
    run_logged(build, output / "build.log", env)
    xctestruns = list((derived / "Build/Products").glob("*.xctestrun"))
    if len(xctestruns) != 1:
        raise RuntimeError("Expected one generated xctestrun")
    with xctestruns[0].open("rb") as stream:
        plan = plistlib.load(stream)
    targets = [t for config in plan.get("TestConfigurations", []) for t in config.get("TestTargets", [])]
    if not targets:
        targets = [value for key, value in plan.items() if not key.startswith("__") and isinstance(value, dict)]
    for target in targets:
        target.setdefault("EnvironmentVariables", {}).update({
            "COMPANYLENS_PERF_ENABLED": "1", "COMPANYLENS_PERF_REPETITIONS": str(args.repetitions),
            "COMPANYLENS_PERF_SCROLL_SECONDS": str(args.scroll_seconds),
            "COMPANYLENS_PERF_FIRST_REPORT_ONLY": "1" if args.scenario == "first-frame" else "0",
            "COMPANYLENS_PERF_ACTIVATE_EXISTING": "1" if args.prelaunch_app else "0"})
    modified = xctestruns[0].with_name("NativePerformance.xctestrun")
    with modified.open("wb") as stream:
        plistlib.dump(plan, stream)
    names = {"journey": "testInstrumentedNativeJourney", "first-frame": "testInstrumentedNativeJourney", "fresh": "testFreshProcessFirstReport",
             "warm": "testWarmModeSwitches", "scroll": "testContinuousScrollAndResume", "jumps": "testContentsDirectedJumps"}
    chosen = [names[key] for key in ("fresh", "warm", "scroll", "jumps")] if args.scenario == "full" else [names[args.scenario]]
    command = ["xcodebuild", "test-without-building", "-xctestrun", str(modified), "-destination", "id=" + args.device,
               "-resultBundlePath", str(output / "native-performance.xcresult"), "-parallel-testing-enabled", "NO"]
    command.extend("-only-testing:CompanyLensUITests/NativeReportPerformanceUITests/" + name for name in chosen)
    metadata = {"started_utc": datetime.now(timezone.utc).isoformat(), "configuration": args.configuration,
                "device_udid": args.device, "scenario": args.scenario, "repetitions": args.repetitions,
                "scroll_seconds": args.scroll_seconds, "xcode": subprocess.check_output(["xcodebuild", "-version"], env=env, text=True).strip(),
                "source": str(source), "study_files": expected,
                "content_baseline_commit": frozen.get("baseline_commit"),
                "production_behavior_changes_by_harness": False,
                "source_diagnostic_overlay": json.loads((source / "diagnostic-overlay.json").read_text())
                    if (source / "diagnostic-overlay.json").is_file() else None,
                "production_files": {group: content_manifest(source / "ios/CompanyLens" / group) for group in ("App", "Core")},
                "harness_tests_source": str(harness_tests),
                "harness_sha256": hashlib.sha256((harness / "ios/CompanyLens/UITests/StudyReadingUITests.swift").read_bytes()).hexdigest(),
                "app_start_method": "devicectl-prelaunch-existing-process" if args.prelaunch_app else "xcui-launch",
                "trace_template": args.trace_template,
                "trace_instruments": ["Time Profiler", *args.trace_instrument],
                "trace_recording_options_sha256": hashlib.sha256(trace_options.read_bytes()).hexdigest() if trace_options else None,
                "thermal_state": "not-observed-record-manually", "low_power_mode": "not-observed-record-manually",
                "battery_and_charging": "not-observed-record-manually", "display_refresh": "not-observed-record-manually",
                "text_size": "not-observed-record-manually", "os_build": "record-device-settings-manually",
                "real_touch_to_readable_frame": "not-measured-by-xcui-proxy"}
    (output / "run-manifest.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n")
    test_log = output / "native-ui.log"
    test_log.touch()
    built_app = derived / "Build/Products" / (args.configuration + "-iphoneos/CompanyLens.app")
    trace = None
    trace_log = None
    trace_started = None
    try:
        metadata["installed_app"] = install_built_app(built_app, args.device, args.configuration, expected, output, "before-tests", env)
        with test_log.open("w") as stream:
            test = subprocess.Popen(command, stdout=stream, stderr=subprocess.STDOUT, env=env)
            if args.record:
                deadline = time.monotonic() + 180
                while test.poll() is None and time.monotonic() < deadline:
                    marker = "COMPANYLENS_PERF_PRELAUNCH_READY" if args.prelaunch_app else "COMPANYLENS_PERF_TRACE_READY"
                    if marker in test_log.read_text(errors="replace"):
                        try:
                            if args.prelaunch_app:
                                metadata["installed_app"] = install_built_app(built_app, args.device, args.configuration, expected,
                                    output, "prelaunch", env)
                                run_logged(["xcrun", "devicectl", "-q", "device", "process", "launch", "--device", args.device,
                                    "--terminate-existing", "com.companylens.prototype"], output / "app-launch.log", env)
                            process = app_process(args.device, env)
                            if not installed_process_matches(process, metadata["installed_app"]):
                                raise RuntimeError("Running app does not match the explicitly installed build path")
                        except (RuntimeError, ValueError, subprocess.CalledProcessError) as error:
                            metadata["trace_status"] = "unresolvable-app-target"
                            metadata["trace_error"] = str(error)
                            break
                        metadata["trace_target_pid"] = process["processIdentifier"]
                        metadata["trace_target_executable"] = process["executable"]
                        trace_log = (output / "instruments.log").open("w")
                        for attempt in range(1, 4):
                            metadata["trace_start_attempts"] = attempt
                            trace = subprocess.Popen(["xcrun", "xctrace", "record", "--template", args.trace_template,
                                *[value for name in metadata["trace_instruments"] for value in ("--instrument", name)],
                                *(["--recording-options", str(trace_options)] if trace_options else []),
                                "--device", args.device, "--attach", str(process["processIdentifier"]),
                                "--time-limit", str(args.trace_seconds) + "s", "--output", str(output / "native-report.trace")],
                                stdout=trace_log, stderr=subprocess.STDOUT, env=env)
                            trace_started = time.monotonic()
                            startup_deadline = trace_started + 5
                            while trace.poll() is None and time.monotonic() < startup_deadline:
                                if "Attaching to:" in (output / "instruments.log").read_text(errors="replace"):
                                    break
                                time.sleep(.1)
                            transient = "Cannot find process for provided pid: " + str(process["processIdentifier"])
                            if trace.poll() != 21 or transient not in (output / "instruments.log").read_text(errors="replace") or attempt == 3:
                                break
                            trace.wait()
                            partial = output / "native-report.trace"
                            if partial.exists():
                                partial.rename(output / ("startup-attempt-" + str(attempt) + ".trace"))
                            time.sleep(1)
                            try:
                                if app_process(args.device, env)["processIdentifier"] != process["processIdentifier"]:
                                    break
                            except (RuntimeError, ValueError, subprocess.CalledProcessError):
                                break
                        break
                    time.sleep(.5)
                if trace is None:
                    metadata.setdefault("trace_status", "not-started-ready-marker-absent")
                elif args.prelaunch_app:
                    ready_deadline = time.monotonic() + 180
                    while test.poll() is None and time.monotonic() < ready_deadline:
                        if "COMPANYLENS_PERF_TRACE_READY" in test_log.read_text(errors="replace"):
                            try:
                                ready_process = app_process(args.device, env)
                                metadata["app_pid_at_measurement_ready"] = ready_process["processIdentifier"]
                                if ready_process["processIdentifier"] != metadata["trace_target_pid"] or not installed_process_matches(
                                        ready_process, metadata["installed_app"]):
                                    metadata["measurement_target_error"] = "app-process-changed-before-measurement"
                            except (RuntimeError, ValueError, subprocess.CalledProcessError):
                                metadata["measurement_target_error"] = "app-target-missing-before-measurement"
                            break
                        time.sleep(.1)
            test_code = test.wait()
            metadata["test_exit_code"] = test_code
        if trace is not None:
            try:
                # Deferred processing can substantially outlive UI completion.
                # Let the configured limit (or target exit) stop recording; retain UI windows separately.
                remaining_recording = max(0, trace_started + args.trace_seconds - time.monotonic())
                metadata["trace_exit_code"] = trace.wait(timeout=remaining_recording + args.trace_finalize_seconds)
                metadata["trace_status"] = ("verified-app-target" if verified_trace_target(
                    (output / "instruments.log").read_text(errors="replace"), metadata["trace_target_pid"])
                    else "invalid-or-missing-app-target")
                if metadata["trace_status"] == "verified-app-target":
                    if metadata["trace_exit_code"] != 0:
                        metadata["trace_status"] = "recording-command-failed"
                    else:
                        try:
                            run_logged(["xcrun", "xctrace", "export", "--input", str(output / "native-report.trace"),
                                "--toc", "--output", str(output / "trace-toc.xml")], output / "trace-export.log", env)
                            toc = ET.parse(output / "trace-toc.xml").getroot()
                            tables = toc.findall("./run/data/table")
                            if not tables:
                                raise ValueError("Trace contains no instrument data tables")
                            target = toc.find("./run/info/target/process")
                            target_pid = metadata["trace_target_pid"]
                            exact_process = any(process.get("pid") == str(target_pid)
                                and Path(process.get("path", "")).parts[-2:] == ("CompanyLens.app", "CompanyLens")
                                for process in toc.findall("./run/processes/process"))
                            if target is None or target.get("pid") != str(target_pid) or not exact_process:
                                metadata["trace_status"] = "invalid-saved-trace-target"
                            else:
                                metadata["trace_tables"] = [table.attrib for table in tables]
                                metadata["primary_metrics_status"] = "not-yet-extracted-or-validated"
                        except (subprocess.CalledProcessError, OSError, ET.ParseError, ValueError) as error:
                            metadata["trace_status"] = "unreadable-trace-data"
                            metadata["trace_error"] = str(error)
            except subprocess.TimeoutExpired:
                trace.kill()
                metadata["trace_exit_code"] = trace.wait(timeout=5)
                metadata["trace_status"] = "finalization-timeout"
    finally:
        if trace_log:
            trace_log.close()
        if metadata.get("measurement_target_error"):
            metadata["trace_status"] = metadata["measurement_target_error"]
        samples = samples_from_log(test_log)
        metadata["observed_runner_conditions"] = [json.loads(line.split("COMPANYLENS_PERF_CONDITIONS ", 1)[1])
            for line in test_log.read_text(errors="replace").splitlines() if "COMPANYLENS_PERF_CONDITIONS " in line]
        (output / "samples.json").write_text(json.dumps(samples, indent=2) + "\n")
        (output / "summary.json").write_text(json.dumps(summarize(samples), indent=2) + "\n")
        (output / "run-manifest.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n")
    print("Evidence:", output)
    print("Native UI exit:", metadata["test_exit_code"], "; samples:", len(samples))
    print("XCUI intervals are automation proxies; inspect the trace before claiming frame/hitch acceptance.")
    if args.record and metadata.get("trace_status") != "verified-app-target":
        return 1
    return metadata["test_exit_code"]


if __name__ == "__main__":
    sys.exit(main())
