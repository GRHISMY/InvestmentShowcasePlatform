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
import time
from datetime import datetime, timezone


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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True, help="Pristine frozen baseline source root or candidate checkout")
    parser.add_argument("--content-manifest", type=Path, required=True)
    parser.add_argument("--device", required=True, help="Physical iPhone UDID (never simulator)")
    parser.add_argument("--configuration", choices=["Debug", "Release"], required=True)
    parser.add_argument("--output", type=Path, required=True, help="New external evidence directory")
    parser.add_argument("--scenario", choices=["journey", "fresh", "warm", "scroll", "jumps", "full"], default="journey")
    parser.add_argument("--repetitions", type=int, default=10)
    parser.add_argument("--scroll-seconds", type=float, default=30)
    parser.add_argument("--trace-seconds", type=int, default=240)
    parser.add_argument("--record", action="store_true", help="Attach Animation Hitches and Time Profiler to CompanyLens only; journey scenario")
    args = parser.parse_args()
    if args.repetitions < 1 or args.scroll_seconds <= 0:
        parser.error("Positive repetitions and scroll duration required")
    if args.record and args.scenario != "journey":
        parser.error("--record requires --scenario journey")
    if args.output.exists():
        parser.error("Output must be a new directory; never overwrite prior evidence")
    source = args.source.resolve()
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
    harness = output / "harness-source"
    shutil.copytree(source, harness, ignore=shutil.ignore_patterns(".git", ".build", "Verification", "DerivedData", "__pycache__"))
    # Replace only an already-included test source. App/Core/Study/project stay byte-for-byte unchanged.
    shutil.copy2(Path(__file__).parents[1] / "UITests/StudyReadingUITests.swift",
                 harness / "ios/CompanyLens/UITests/StudyReadingUITests.swift")
    verify_content(harness / "ios/CompanyLens/Study", expected)
    project = harness / "ios/CompanyLens/CompanyLens.xcodeproj"
    derived = output / "DerivedData"
    build = ["xcodebuild", "-project", str(project), "-scheme", "CompanyLens", "-configuration", args.configuration,
             "-destination", "id=" + args.device, "-derivedDataPath", str(derived), "-allowProvisioningUpdates", "build-for-testing"]
    print("Building the unmodified native app plus opt-in test harness; logs remain local.", flush=True)
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
            "COMPANYLENS_PERF_SCROLL_SECONDS": str(args.scroll_seconds)})
    modified = xctestruns[0].with_name("NativePerformance.xctestrun")
    with modified.open("wb") as stream:
        plistlib.dump(plan, stream)
    names = {"journey": "testInstrumentedNativeJourney", "fresh": "testFreshProcessFirstReport",
             "warm": "testWarmModeSwitches", "scroll": "testContinuousScrollAndResume", "jumps": "testContentsDirectedJumps"}
    chosen = list(names.values())[1:] if args.scenario == "full" else [names[args.scenario]]
    command = ["xcodebuild", "test-without-building", "-xctestrun", str(modified), "-destination", "id=" + args.device,
               "-resultBundlePath", str(output / "native-performance.xcresult"), "-parallel-testing-enabled", "NO"]
    command.extend("-only-testing:CompanyLensUITests/NativeReportPerformanceUITests/" + name for name in chosen)
    metadata = {"started_utc": datetime.now(timezone.utc).isoformat(), "configuration": args.configuration,
                "device_udid": args.device, "scenario": args.scenario, "repetitions": args.repetitions,
                "scroll_seconds": args.scroll_seconds, "xcode": subprocess.check_output(["xcodebuild", "-version"], env=env, text=True).strip(),
                "source": str(source), "study_files": expected,
                "content_baseline_commit": frozen.get("baseline_commit"),
                "production_behavior_changes_by_harness": False,
                "production_files": {group: content_manifest(source / "ios/CompanyLens" / group) for group in ("App", "Core")},
                "harness_sha256": hashlib.sha256((harness / "ios/CompanyLens/UITests/StudyReadingUITests.swift").read_bytes()).hexdigest(),
                "thermal_state": "not-observed-record-manually", "low_power_mode": "not-observed-record-manually",
                "battery_and_charging": "not-observed-record-manually", "display_refresh": "not-observed-record-manually",
                "text_size": "not-observed-record-manually", "os_build": "record-device-settings-manually",
                "real_touch_to_readable_frame": "not-measured-by-xcui-proxy"}
    (output / "run-manifest.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n")
    test_log = output / "native-ui.log"
    trace = None
    trace_log = None
    try:
        with test_log.open("w") as stream:
            test = subprocess.Popen(command, stdout=stream, stderr=subprocess.STDOUT, env=env)
            if args.record:
                deadline = time.monotonic() + 180
                while test.poll() is None and time.monotonic() < deadline:
                    if "COMPANYLENS_PERF_TRACE_READY" in test_log.read_text(errors="replace"):
                        trace_log = (output / "instruments.log").open("w")
                        trace = subprocess.Popen(["xcrun", "xctrace", "record", "--template", "Animation Hitches",
                            "--instrument", "Time Profiler", "--device", args.device, "--attach", "CompanyLens",
                            "--time-limit", str(args.trace_seconds) + "s", "--output", str(output / "native-report.trace")],
                            stdout=trace_log, stderr=subprocess.STDOUT, env=env)
                        break
                    time.sleep(.5)
                if trace is None:
                    metadata["trace_status"] = "not-started-ready-marker-absent"
            test_code = test.wait()
        if trace is not None:
            if trace.poll() is None:
                trace.send_signal(2)
            metadata["trace_exit_code"] = trace.wait(timeout=60)
        metadata["test_exit_code"] = test_code
    finally:
        if trace_log:
            trace_log.close()
        samples = samples_from_log(test_log)
        (output / "samples.json").write_text(json.dumps(samples, indent=2) + "\n")
        (output / "summary.json").write_text(json.dumps(summarize(samples), indent=2) + "\n")
        (output / "run-manifest.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n")
    print("Evidence:", output)
    print("Native UI exit:", metadata["test_exit_code"], "; samples:", len(samples))
    print("XCUI intervals are automation proxies; inspect the trace before claiming frame/hitch acceptance.")
    return metadata["test_exit_code"]


if __name__ == "__main__":
    sys.exit(main())
