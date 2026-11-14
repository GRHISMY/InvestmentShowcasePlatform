"""Exercise publication trust and rollback using a real one-page PDF."""
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

import prepare_resources as packaging


def write_pdf(path):
    stream = b"BT /F1 12 Tf 50 750 Td (Original annual report) Tj ET"
    objects = [b"<< /Type /Catalog /Pages 2 0 R >>", b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
               b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
               b"<< /Length " + str(len(stream)).encode() + b" >>\nstream\n" + stream + b"\nendstream",
               b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
    data, offsets = bytearray(b"%PDF-1.4\n"), [0]
    for number, obj in enumerate(objects, 1):
        offsets.append(len(data))
        data.extend(f"{number} 0 obj\n".encode() + obj + b"\nendobj\n")
    xref = len(data)
    data.extend(f"xref\n0 {len(offsets)}\n0000000000 65535 f \n".encode())
    for offset in offsets[1:]:
        data.extend(f"{offset:010d} 00000 n \n".encode())
    data.extend(f"trailer\n<< /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode())
    path.write_bytes(data)


def inventory(root):
    return {str(p.relative_to(root)): p.read_bytes() for p in root.rglob("*") if p.is_file()}


@unittest.skipUnless(shutil.which("pdfinfo"), "Poppler pdfinfo is required")
class PublicationPackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.case = self.root / "case"
        self.snapshot = self.case / "published/research/sample-r3"
        (self.snapshot / "reports").mkdir(parents=True)
        self.pdf = self.snapshot / "reports/source.pdf"
        write_pdf(self.pdf)
        self.research = {
            "schema_version": "company-research/v1.1",
            "publication": {"snapshot_id": "sample-r3"},
            "report": {"research_as_of": "2026-11-09", "coverage": {"start": "2020-01-01", "end": "2026-09-30"},
                       "review": {"status": "reviewed"}},
            "sources": [{"id": "source", "title": "Original annual report", "sha256": packaging.digest(self.pdf),
                         "asset_path": "reports/source.pdf", "pdf_pages": 1}],
            "evidence": [{"id": "e1", "source_id": "source", "physical_pages": [1]}],
            "conclusions": [{"id": "free-form-claim", "statement": "A clear researched explanation."}],
            "facts": [], "calculations": [],
        }
        packaging.write_json(self.snapshot / "research.json", self.research)
        (self.snapshot / "research.md").write_text("# Clear explanation\n")
        (self.snapshot / "evidence.md").write_text("# Original evidence\n")
        self.pin()
        self.resources = self.root / "Study"
        self.resources.mkdir()
        (self.resources / "gree-logo.png").write_bytes(b"existing-logo")
        (self.resources / "research-data.json").write_text("old sample must disappear only on success")
        self.old = inventory(self.resources)

    def pin(self, extra=None):
        files = {str(p.relative_to(self.snapshot)): packaging.digest(p)
                 for p in self.snapshot.rglob("*") if p.is_file() and p.name != "snapshot.json"}
        files.update(extra or {})
        packaging.write_json(self.snapshot / "snapshot.json", {"snapshot_id": "sample-r3", "files": files})
        packaging.write_json(self.case / "published/research/current.json", {
            "snapshot_id": "sample-r3", "manifest": "published/research/sample-r3/snapshot.json",
            "sha256": packaging.digest(self.snapshot / "snapshot.json"),
        })

    def test_exact_copy_logo_preservation_and_repeatability(self):
        source_before = inventory(self.case)
        first = packaging.prepare(self.case, self.resources)
        expected = inventory(self.resources)
        self.assertEqual((self.resources / "research.json").read_bytes(), (self.snapshot / "research.json").read_bytes())
        self.assertEqual((self.resources / "reports/source.pdf").read_bytes(), self.pdf.read_bytes())
        self.assertEqual((self.resources / "gree-logo.png").read_bytes(), b"existing-logo")
        self.assertFalse((self.resources / "research-data.json").exists())
        self.assertEqual(first["conclusions"], 1)
        self.assertEqual(first["documents"], 1)
        self.assertEqual(first, packaging.prepare(self.case, self.resources))
        self.assertEqual(expected, inventory(self.resources))
        self.assertEqual(source_before, inventory(self.case))

    def test_tampered_payload_and_manifest_preserve_existing_resources(self):
        for file in ("research.md", "snapshot.json"):
            with self.subTest(file=file):
                path = self.snapshot / file
                before = path.read_bytes()
                path.write_bytes(before + b"tampered")
                with self.assertRaises(ValueError):
                    packaging.prepare(self.case, self.resources)
                self.assertEqual(self.old, inventory(self.resources))
                path.write_bytes(before)

    def test_compiled_reading_is_copied_and_preserved_on_repeat(self):
        reading = {"schema_version": "company-reading/v1", "research_ref": {
            "snapshot_id": "sample-r3", "sha256": packaging.digest(self.snapshot / "research.json")},
            "scenes": [{"id": "a"}], "focuses": [{"id": "f"}]}
        packaging.write_json(self.snapshot / "reading.json", reading)
        self.pin()
        result = packaging.prepare(self.case, self.resources)
        self.assertTrue(result["compiledReading"])
        expected = (self.snapshot / "reading.json").read_bytes()
        self.assertEqual((self.resources / "reading.json").read_bytes(), expected)
        packaging.prepare(self.case, self.resources)
        self.assertEqual((self.resources / "reading.json").read_bytes(), expected)

    def test_reading_with_another_research_hash_preserves_previous_resources(self):
        packaging.write_json(self.snapshot / "reading.json", {"schema_version": "company-reading/v1",
            "research_ref": {"snapshot_id": "sample-r3", "sha256": "0" * 64},
            "scenes": [{"id": "a"}], "focuses": [{"id": "f"}]})
        self.pin()
        with self.assertRaisesRegex(ValueError, "exact research snapshot"):
            packaging.prepare(self.case, self.resources)
        self.assertEqual(self.old, inventory(self.resources))

    def test_traversal_and_symlink_escape_are_rejected(self):
        outside = self.case / "outside.txt"
        outside.write_text("not part of the publication")
        self.pin({"../../../outside.txt": packaging.digest(outside)})
        with self.assertRaisesRegex(ValueError, "stay inside"):
            packaging.prepare(self.case, self.resources)
        self.pin()
        link = self.snapshot / "reports/leak.pdf"
        link.symlink_to(outside)
        self.pin()
        with self.assertRaisesRegex(ValueError, "leaves"):
            packaging.prepare(self.case, self.resources)
        self.assertEqual(self.old, inventory(self.resources))

    def test_source_page_count_is_checked_against_actual_pdf(self):
        self.research["sources"][0]["pdf_pages"] = 2
        packaging.write_json(self.snapshot / "research.json", self.research)
        self.pin()
        with self.assertRaisesRegex(ValueError, "page count mismatch"):
            packaging.prepare(self.case, self.resources)
        self.assertEqual(self.old, inventory(self.resources))

    def test_copy_failure_preserves_previous_directory(self):
        with patch.object(packaging.shutil, "copyfile", side_effect=OSError("disk failure")):
            with self.assertRaisesRegex(OSError, "disk failure"):
                packaging.prepare(self.case, self.resources)
        self.assertEqual(self.old, inventory(self.resources))
        self.assertFalse(list(self.root.glob(".resources-*")))

    def test_directory_replacement_failure_restores_previous_directory(self):
        rename = Path.rename
        def fail_stage(path, target):
            if path.name.startswith(".resources-stage-"):
                raise OSError("replacement failure")
            return rename(path, target)
        with patch.object(Path, "rename", fail_stage):
            with self.assertRaisesRegex(OSError, "replacement failure"):
                packaging.prepare(self.case, self.resources)
        self.assertEqual(self.old, inventory(self.resources))
        self.assertFalse(list(self.root.glob(".resources-*")))


if __name__ == "__main__":
    unittest.main()
