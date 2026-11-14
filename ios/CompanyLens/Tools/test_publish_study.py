"""Exercise the public Mac distribution operation with real files and PDFs."""
import hashlib
from concurrent.futures import ThreadPoolExecutor
import copy
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

from test_prepare_resources import write_pdf


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def inventory(root):
    return {str(path.relative_to(root)): path.read_bytes()
            for path in root.rglob("*") if path.is_file()}


def publication(root, company="sample-company", snapshot_id="sample-r1", revision=1):
    case = root / company / snapshot_id
    snapshot = case / "published/research" / snapshot_id
    (snapshot / "reports").mkdir(parents=True)
    pdf = snapshot / "reports/source.pdf"
    write_pdf(pdf)
    research = {
        "schema_version": "company-research/v1.2",
        "company": {"id": company, "name": "Sample Company", "code": "SAMPLE", "exchange": "TEST"},
        "publication": {"snapshot_id": snapshot_id, "manifest_sha256": "f" * 64},
        "report": {"id": company + "-study", "revision": revision, "research_as_of": "2026-11-09",
                   "coverage": {"start": "2020-01-01", "end": "2026-09-30"},
                   "review": {"status": "reviewed"}},
        "sources": [{"id": "source", "title": "Original annual report", "sha256": sha(pdf),
                     "asset_path": "reports/source.pdf", "pdf_pages": 1}],
        "evidence": [{"id": "e1", "source_id": "source", "physical_pages": [1]}],
        "conclusions": [], "facts": [], "calculations": [],
    }
    write_json(snapshot / "research.json", research)
    (snapshot / "research.md").write_text("# Research\n", encoding="utf-8")
    (snapshot / "evidence.md").write_text("# Evidence\n", encoding="utf-8")
    pin(case, snapshot)
    return case, snapshot


def pin(case, snapshot):
    files = {str(path.relative_to(snapshot)): sha(path) for path in snapshot.rglob("*")
             if path.is_file() and path.name != "snapshot.json"}
    write_json(snapshot / "snapshot.json", {
        "schema_version": "cfa-research-snapshot/v1", "snapshot_id": snapshot.name, "files": files,
    })
    write_json(case / "published/research/current.json", {
        "schema_version": "cfa-research-current/v1", "snapshot_id": snapshot.name,
        "manifest": "published/research/" + snapshot.name + "/snapshot.json",
        "sha256": sha(snapshot / "snapshot.json"),
    })


@unittest.skipUnless(shutil.which("pdfinfo"), "Poppler pdfinfo is required")
class StudyDistributionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.case, self.snapshot = publication(self.root / "cases")
        self.library = self.root / "library"

    def publish(self, case=None):
        import publish_study
        return publish_study.publish(case or self.case, self.library)

    def catalog(self):
        return json.loads((self.library / "catalog.json").read_text(encoding="utf-8"))

    def test_formal_publication_is_discoverable_and_source_bytes_are_unchanged(self):
        before = inventory(self.case)
        result = self.publish()
        catalog = self.catalog()
        self.assertEqual(catalog["schemaVersion"], 1)
        company = catalog["companies"][0]
        self.assertEqual(company["company"]["id"], "sample-company")
        version = company["versions"][0]
        self.assertEqual(company["currentVersionId"], version["versionId"])
        self.assertEqual(version["snapshotId"], "sample-r1")
        self.assertEqual(version["snapshotManifestSHA256"], sha(self.snapshot / "snapshot.json"))
        self.assertNotEqual(version["snapshotManifestSHA256"], "f" * 64)
        self.assertEqual(version["reportRevision"], 1)
        self.assertEqual(version["researchAsOf"], "2026-11-09")
        self.assertEqual(version["financialPeriodStart"], "2020-01-01")
        self.assertEqual(version["financialPeriodEnd"], "2026-09-30")
        package = self.library / version["packagePath"]
        self.assertEqual(result["packagePath"], version["packagePath"])
        self.assertEqual(version["resourceManifestSHA256"], sha(package / "resource-manifest.json"))
        self.assertEqual((package / "reports/source.pdf").read_bytes(),
                         (self.snapshot / "reports/source.pdf").read_bytes())
        for relative, data in before.items():
            if relative.startswith("published/research/sample-r1/"):
                self.assertEqual((package / Path(relative).relative_to("published/research/sample-r1")).read_bytes(), data)
        self.assertEqual(inventory(self.case), before)

    def test_republishing_the_same_version_does_not_rewrite_the_package_or_catalog(self):
        self.publish()
        before = inventory(self.library)
        catalog_time = (self.library / "catalog.json").stat().st_mtime_ns
        result = self.publish()
        self.assertFalse(result["created"])
        self.assertEqual(inventory(self.library), before)
        self.assertEqual((self.library / "catalog.json").stat().st_mtime_ns, catalog_time)

    def test_republishing_rejects_changed_existing_bytes_without_repairing_or_rewriting(self):
        result = self.publish()
        package = self.library / result["packagePath"]
        for relative in ("reports/source.pdf", "resource-manifest.json", "unexpected.txt"):
            with self.subTest(relative=relative):
                path = package / relative
                original = path.read_bytes() if path.exists() else None
                path.write_bytes((original or b"") + b"unexpected bytes")
                before = inventory(self.library)
                with self.assertRaisesRegex(ValueError, "Existing version"):
                    self.publish()
                self.assertEqual(inventory(self.library), before)
                if original is None:
                    path.unlink()
                else:
                    path.write_bytes(original)

    def test_new_version_retains_the_old_package_and_old_repeat_does_not_roll_back_current(self):
        first = self.publish()
        old_package = inventory(self.library / first["packagePath"])
        next_case, _ = publication(self.root / "cases", snapshot_id="sample-r2", revision=2)
        second = self.publish(next_case)
        company = self.catalog()["companies"][0]
        self.assertEqual(len(company["versions"]), 2)
        self.assertEqual(company["currentVersionId"], second["versionId"])
        self.assertEqual(inventory(self.library / first["packagePath"]), old_package)
        before = (self.library / "catalog.json").read_bytes()
        self.publish()
        self.assertEqual((self.library / "catalog.json").read_bytes(), before)

    def test_command_line_publishes_a_formal_case_to_the_selected_library(self):
        result = subprocess.run([sys.executable, str(Path(__file__).with_name("publish_study.py")),
                                 "--case", str(self.case), "--library", str(self.library)],
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        output = json.loads(result.stdout)
        self.assertEqual(output["companyId"], "sample-company")
        self.assertTrue((self.library / output["packagePath"] / "research.json").is_file())

    def test_catalog_commit_failure_preserves_the_previous_publication(self):
        self.publish()
        before = inventory(self.library)
        next_case, _ = publication(self.root / "cases", snapshot_id="sample-r2", revision=2)
        import os
        replace = os.replace

        def full_disk(source, target):
            if Path(target).name == "catalog.json":
                raise OSError("catalog disk is full")
            return replace(source, target)

        with patch("os.replace", full_disk):
            with self.assertRaisesRegex(OSError, "disk is full"):
                self.publish(next_case)
        self.assertEqual(inventory(self.library), before)
        self.assertFalse(list(self.library.glob(".publish-stage-*")))

    def test_a_library_inside_the_formal_case_is_rejected_before_writing(self):
        before = inventory(self.case)
        self.library = self.case / "distribution"
        with self.assertRaisesRegex(ValueError, "overlap"):
            self.publish()
        self.assertEqual(inventory(self.case), before)
        self.assertFalse(self.library.exists())

    def test_library_paths_cannot_redirect_writes_through_symbolic_links(self):
        for index, relative in enumerate(("", "packages", "catalog.json")):
            with self.subTest(relative=relative):
                self.library = self.root / ("library-link-" + str(index))
                outside = self.root / ("outside-" + str(index))
                outside.mkdir()
                (outside / "keep.txt").write_text("untouched", encoding="utf-8")
                if relative == "":
                    self.library.symlink_to(outside, target_is_directory=True)
                else:
                    self.library.mkdir()
                    destination = outside
                    if relative == "catalog.json":
                        destination = outside / "catalog.json"
                        write_json(destination, {"schemaVersion": 1, "companies": []})
                    (self.library / relative).symlink_to(destination)
                before = inventory(outside)
                with self.assertRaisesRegex(ValueError, "symbolic link"):
                    self.publish()
                self.assertEqual(inventory(outside), before)

    def test_concurrent_company_publications_do_not_lose_catalog_entries(self):
        self.publish()
        cases = [publication(self.root / "cases", company="company-" + str(index))[0]
                 for index in range(12)]
        start = threading.Barrier(len(cases))

        def distribute(case):
            start.wait(timeout=10)
            return self.publish(case)

        with ThreadPoolExecutor(max_workers=len(cases)) as executor:
            results = list(executor.map(distribute, cases))
        companies = self.catalog()["companies"]
        self.assertEqual({item["company"]["id"] for item in companies},
                         {"sample-company"} | {"company-" + str(index) for index in range(12)})
        for result in results:
            self.assertTrue((self.library / result["packagePath"] / "research.json").is_file())

    def test_invalid_existing_catalog_is_not_overwritten_or_used_for_new_publication(self):
        self.publish()
        original = self.catalog()
        next_case, _ = publication(self.root / "cases", snapshot_id="sample-r2", revision=2)
        variants = []
        invalid = copy.deepcopy(original)
        invalid["schemaVersion"] = 2
        variants.append(invalid)
        invalid = copy.deepcopy(original)
        invalid["companies"].append(copy.deepcopy(invalid["companies"][0]))
        variants.append(invalid)
        invalid = copy.deepcopy(original)
        invalid["companies"][0]["currentVersionId"] = "missing-version"
        variants.append(invalid)
        invalid = copy.deepcopy(original)
        invalid["companies"][0]["versions"][0]["packagePath"] = "../outside"
        variants.append(invalid)
        invalid = copy.deepcopy(original)
        del invalid["companies"][0]["company"]["name"]
        variants.append(invalid)
        invalid = copy.deepcopy(original)
        del invalid["companies"][0]["versions"][0]["researchAsOf"]
        variants.append(invalid)
        for index, invalid in enumerate(variants):
            with self.subTest(index=index):
                write_json(self.library / "catalog.json", invalid)
                before = inventory(self.library)
                with self.assertRaisesRegex(ValueError, "catalog"):
                    self.publish(next_case)
                self.assertEqual(inventory(self.library), before)

    def test_invalid_publication_metadata_cannot_create_unsafe_or_unusable_catalog_entries(self):
        self.publish()
        before = inventory(self.library)
        original = json.loads((self.snapshot / "research.json").read_text(encoding="utf-8"))
        for section, field, value in (("company", "id", "unsafe/nested"),
                                      ("company", "name", ""),
                                      ("report", "revision", 0),
                                      ("report", "research_as_of", "not-a-date")):
            with self.subTest(field=section + "." + field):
                research = copy.deepcopy(original)
                research[section][field] = value
                write_json(self.snapshot / "research.json", research)
                pin(self.case, self.snapshot)
                with self.assertRaisesRegex(ValueError, "metadata"):
                    self.publish()
                self.assertEqual(inventory(self.library), before)

    def test_unknown_formal_publication_envelopes_are_rejected(self):
        self.publish()
        before = inventory(self.library)
        for envelope in ("snapshot", "pointer"):
            with self.subTest(envelope=envelope):
                pin(self.case, self.snapshot)
                pointer_path = self.case / "published/research/current.json"
                path = self.snapshot / "snapshot.json" if envelope == "snapshot" else pointer_path
                value = json.loads(path.read_text(encoding="utf-8"))
                value["schema_version"] = "unsupported/v999"
                write_json(path, value)
                if envelope == "snapshot":
                    pointer = json.loads(pointer_path.read_text(encoding="utf-8"))
                    pointer["sha256"] = sha(path)
                    write_json(pointer_path, pointer)
                with self.assertRaisesRegex(ValueError, "publication envelope"):
                    self.publish()
                self.assertEqual(inventory(self.library), before)

    def test_catalog_staging_write_failure_does_not_publish_a_partial_transaction(self):
        self.publish()
        before = inventory(self.library)
        next_case, _ = publication(self.root / "cases", snapshot_id="sample-r2", revision=2)
        original_open = Path.open

        def disk_full(path, mode="r", *args, **kwargs):
            if path.name == "catalog.json" and "w" in mode:
                raise OSError("catalog staging disk is full")
            return original_open(path, mode, *args, **kwargs)

        with patch.object(Path, "open", disk_full):
            with self.assertRaisesRegex(OSError, "staging disk is full"):
                self.publish(next_case)
        self.assertEqual(inventory(self.library), before)

    def test_existing_version_catalog_metadata_must_match_the_verified_package(self):
        self.publish()
        catalog = self.catalog()
        catalog["companies"][0]["versions"][0]["resourceManifestSHA256"] = "0" * 64
        write_json(self.library / "catalog.json", catalog)
        before = inventory(self.library)
        with self.assertRaisesRegex(ValueError, "catalog metadata"):
            self.publish()
        self.assertEqual(inventory(self.library), before)

    def test_wrong_source_declarations_fail_even_when_outer_manifest_hashes_match(self):
        self.publish()
        before = inventory(self.library)
        original = json.loads((self.snapshot / "research.json").read_text(encoding="utf-8"))
        for field, value in (("sha256", "0" * 64), ("pdf_pages", 2)):
            with self.subTest(field=field):
                research = copy.deepcopy(original)
                research["sources"][0][field] = value
                write_json(self.snapshot / "research.json", research)
                pin(self.case, self.snapshot)
                source_before = inventory(self.case)
                with self.assertRaisesRegex(ValueError, "(hash mismatch|page count mismatch)"):
                    self.publish()
                self.assertEqual(inventory(self.library), before)
                self.assertEqual(inventory(self.case), source_before)

    def test_catalog_first_fixture_can_be_completed_without_changing_its_version_identity(self):
        self.publish()
        catalog_bytes = (self.library / "catalog.json").read_bytes()
        partial_library = self.root / "catalog-first-library"
        partial_library.mkdir()
        (partial_library / "catalog.json").write_bytes(catalog_bytes)
        version = self.catalog()["companies"][0]["versions"][0]
        self.assertFalse((partial_library / version["packagePath"]).exists())
        self.library = partial_library
        result = self.publish()
        self.assertTrue(result["created"])
        self.assertEqual((self.library / "catalog.json").read_bytes(), catalog_bytes)
        self.assertEqual(sha(self.library / version["packagePath"] / "snapshot.json"),
                         version["snapshotManifestSHA256"])

    def test_concurrent_command_line_repeats_publish_one_immutable_version(self):
        command = [sys.executable, str(Path(__file__).with_name("publish_study.py")),
                   "--case", str(self.case), "--library", str(self.library)]
        processes = [subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                     for _ in range(4)]
        results = []
        for process in processes:
            output, errors = process.communicate(timeout=30)
            self.assertEqual(process.returncode, 0, errors)
            results.append(json.loads(output))
        self.assertEqual(sum(result["created"] for result in results), 1)
        self.assertEqual(len(self.catalog()["companies"]), 1)
        self.assertEqual(len(self.catalog()["companies"][0]["versions"]), 1)

    def test_interruption_after_catalog_commit_keeps_the_referenced_package_for_idempotent_retry(self):
        import os
        replace = os.replace
        next_case, _ = publication(self.root / "cases", snapshot_id="sample-r2", revision=2)
        for index, error_type in enumerate((KeyboardInterrupt, OSError)):
            with self.subTest(error_type=error_type.__name__):
                self.library = self.root / ("commit-uncertain-" + str(index))
                first = self.publish()
                old_package = inventory(self.library / first["packagePath"])

                def committed_without_acknowledgement(source, target):
                    replace(source, target)
                    if Path(target).name == "catalog.json":
                        raise error_type("catalog commit acknowledgement lost")

                with patch("os.replace", committed_without_acknowledgement):
                    with self.assertRaisesRegex(error_type, "acknowledgement lost"):
                        self.publish(next_case)
                company = self.catalog()["companies"][0]
                current = next(version for version in company["versions"]
                               if version["versionId"] == company["currentVersionId"])
                package = self.library / current["packagePath"]
                self.assertEqual(current["snapshotId"], "sample-r2")
                self.assertTrue((package / "research.json").is_file())
                self.assertEqual(sha(package / "snapshot.json"), current["snapshotManifestSHA256"])
                self.assertEqual(inventory(self.library / first["packagePath"]), old_package)
                catalog_before_retry = (self.library / "catalog.json").read_bytes()
                retry = self.publish(next_case)
                self.assertFalse(retry["created"])
                self.assertEqual((self.library / "catalog.json").read_bytes(), catalog_before_retry)

    def test_unreadable_catalog_after_uncertain_commit_retains_the_complete_package_for_retry(self):
        import os
        self.publish()
        catalog_before = (self.library / "catalog.json").read_bytes()
        next_case, next_snapshot = publication(self.root / "cases", snapshot_id="sample-r2", revision=2)
        replace, original_open = os.replace, Path.open
        uncertain = False

        def lose_commit_result(source, target):
            nonlocal uncertain
            if Path(target).name == "catalog.json":
                uncertain = True
                raise OSError("catalog outcome unavailable")
            return replace(source, target)

        def cannot_observe_catalog(path, mode="r", *args, **kwargs):
            if uncertain and path.name == "catalog.json" and mode.startswith("r"):
                raise PermissionError("catalog temporarily unreadable")
            return original_open(path, mode, *args, **kwargs)

        with patch("os.replace", lose_commit_result), patch.object(Path, "open", cannot_observe_catalog):
            with self.assertRaisesRegex(OSError, "outcome unavailable"):
                self.publish(next_case)
        self.assertEqual((self.library / "catalog.json").read_bytes(), catalog_before)
        packages = list((self.library / "packages/sample-company").glob("sample-r2--*"))
        self.assertEqual(len(packages), 1)
        self.assertEqual((packages[0] / "research.json").read_bytes(),
                         (next_snapshot / "research.json").read_bytes())
        retry = self.publish(next_case)
        self.assertFalse(retry["created"])
        company = self.catalog()["companies"][0]
        self.assertEqual(company["currentVersionId"], retry["versionId"])
        self.assertEqual(len(company["versions"]), 2)


if __name__ == "__main__":
    unittest.main()
