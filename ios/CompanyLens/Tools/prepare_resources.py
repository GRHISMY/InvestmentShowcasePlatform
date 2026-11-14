"""Bundle the current immutable research publication, without rewriting it.

The selected case is read-only. The complete JSON, Markdown and original PDFs
are copied together after their published hashes and physical pages are checked.
Study is replaced only after preparation succeeds; replacement errors restore
the previous directory. The logo is an app asset and is preserved separately.
The name avoids a top-level Resources directory being treated as a legacy bundle.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import uuid

APP_ROOT = Path(__file__).resolve().parents[1]
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
SAFE_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*\Z")
REQUIRED = {"research.json", "research.md", "evidence.md"}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def contained_file(root, relative):
    if not isinstance(relative, str) or not relative or "\\" in relative:
        raise ValueError("Invalid relative resource path: " + str(relative))
    path = Path(relative)
    if path.is_absolute() or any(part in {"..", "."} for part in relative.split("/")):
        raise ValueError("Resource path must stay inside its directory: " + relative)
    target = (root / path).resolve(strict=True)
    if not target.is_relative_to(root) or not target.is_file():
        raise ValueError("Resource path leaves its directory: " + relative)
    return target


def checked_hash(path, expected, label):
    if not isinstance(expected, str) or SHA256.fullmatch(expected) is None:
        raise ValueError("Missing or invalid SHA256: " + label)
    if digest(path) != expected:
        raise ValueError("Published hash mismatch: " + label)


def pdf_pages(path):
    result = subprocess.run(
        ["pdfinfo", str(path)], capture_output=True, text=True, timeout=30,
        env={**os.environ, "LC_ALL": "C"},
    )
    match = re.search(r"^Pages:\s+(\d+)\s*$", result.stdout, re.MULTILINE)
    if result.returncode or match is None:
        raise ValueError("Cannot read original PDF page count: " + str(path))
    return int(match.group(1))


def validated_publication(case):
    pointer_path = case / "published/research/current.json"
    pointer_bytes = pointer_path.read_bytes()
    pointer = json.loads(pointer_bytes)
    snapshot_id = pointer.get("snapshot_id")
    if not isinstance(snapshot_id, str) or SAFE_ID.fullmatch(snapshot_id) is None:
        raise ValueError("Invalid current snapshot identity")
    expected_manifest = "published/research/" + snapshot_id + "/snapshot.json"
    if pointer.get("manifest") != expected_manifest:
        raise ValueError("Current manifest does not match its snapshot identity")
    snapshot_path = contained_file(case, expected_manifest)
    checked_hash(snapshot_path, pointer.get("sha256"), "current snapshot manifest")
    snapshot = read_json(snapshot_path)
    if snapshot.get("snapshot_id") != snapshot_id:
        raise ValueError("Current pointer and snapshot identify different publications")
    snapshot_root = snapshot_path.parent
    files = snapshot.get("files")
    if not isinstance(files, dict) or not REQUIRED.issubset(files):
        raise ValueError("Publication must contain research JSON and both Markdown views")
    if {"snapshot.json", "resource-manifest.json", "gree-logo.png"}.intersection(files):
        raise ValueError("Publication payload collides with app packaging metadata or artwork")
    for relative, expected in files.items():
        checked_hash(contained_file(snapshot_root, relative), expected, relative)
    research = read_json(snapshot_root / "research.json")
    if research.get("schema_version") not in {"company-research/v1", "company-research/v1.1", "company-research/v1.2"}:
        raise ValueError("Unsupported company research publication")
    if research.get("publication", {}).get("snapshot_id") != snapshot_id:
        raise ValueError("Research JSON belongs to a different snapshot")
    if research.get("report", {}).get("review", {}).get("status") != "reviewed":
        raise ValueError("The research publication has not been explicitly reviewed")
    if "reading.json" in files:
        reading = read_json(snapshot_root / "reading.json")
        if reading.get("schema_version") != "company-reading/v1":
            raise ValueError("Unsupported compiled reading publication")
        binding = reading.get("research_ref", {})
        if binding.get("snapshot_id") != snapshot_id or binding.get("sha256") != digest(snapshot_root / "research.json"):
            raise ValueError("Reading publication does not match its exact research snapshot")
        if not reading.get("scenes") or not reading.get("focuses"):
            raise ValueError("Reading publication has no usable scenes or focuses")

    documents = []
    source_pages = {}
    assets = set()
    for source in research["sources"]:
        source_id, asset = source["id"], source["asset_path"]
        if not isinstance(source_id, str) or SAFE_ID.fullmatch(source_id) is None or source_id in source_pages:
            raise ValueError("Duplicate or invalid source identity: " + str(source_id))
        parts = Path(asset).parts
        if len(parts) != 2 or parts[0] != "reports" or Path(asset).suffix.lower() != ".pdf":
            raise ValueError("Source asset must be a PDF in reports: " + str(asset))
        if asset in assets or asset not in files:
            raise ValueError("Source asset is duplicate or absent from publication: " + asset)
        original = contained_file(snapshot_root, asset)
        checked_hash(original, source.get("sha256"), source_id)
        if files[asset] != source["sha256"]:
            raise ValueError("Source and snapshot disagree about PDF identity: " + source_id)
        actual_pages = pdf_pages(original)
        if type(source.get("pdf_pages")) is not int or source["pdf_pages"] != actual_pages or actual_pages < 1:
            raise ValueError("Source PDF page count mismatch: " + source_id)
        assets.add(asset)
        source_pages[source_id] = actual_pages
        documents.append({
            "sourceId": source_id, "title": source["title"], "documentFile": asset,
            "sha256": source["sha256"], "bytes": original.stat().st_size,
            "pageCount": actual_pages,
        })
    if {name for name in files if Path(name).suffix.lower() == ".pdf"} != assets:
        raise ValueError("Published PDFs and declared research sources differ")
    references = 0
    for evidence in research["evidence"]:
        count = source_pages.get(evidence["source_id"])
        pages = evidence["physical_pages"]
        if count is None or not pages or any(type(page) is not int or not 1 <= page <= count for page in pages):
            raise ValueError("Evidence points outside its original PDF: " + evidence["id"])
        references += len(pages)
    if pointer_path.read_bytes() != pointer_bytes:
        raise ValueError("Current publication changed during preparation; retry")
    return pointer, snapshot_path, snapshot, research, documents, references


def prepare(case, resources=None):
    case = case.expanduser().resolve(strict=True)
    resources = Path(resources) if resources is not None else APP_ROOT / "Study"
    resources = resources.absolute()
    resources.parent.mkdir(parents=True, exist_ok=True)
    if resources.is_symlink():
        raise ValueError("Study must not be a symbolic link")
    pointer, snapshot_path, snapshot, research, documents, references = validated_publication(case)
    stage = Path(tempfile.mkdtemp(prefix=".resources-stage-", dir=resources.parent))
    backup = resources.with_name(".resources-backup-" + uuid.uuid4().hex)
    try:
        for relative, expected in snapshot["files"].items():
            target = stage / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(contained_file(snapshot_path.parent, relative), target)
            checked_hash(target, expected, "copied " + relative)
        shutil.copyfile(snapshot_path, stage / "snapshot.json")
        checked_hash(stage / "snapshot.json", pointer["sha256"], "copied snapshot manifest")
        logo = resources / "gree-logo.png"
        if logo.is_file():
            shutil.copyfile(logo, stage / logo.name)
        datasets = sorted(path for path in stage.iterdir() if path.is_file())
        write_json(stage / "resource-manifest.json", {
            "schemaVersion": 3,
            "snapshotId": pointer["snapshot_id"],
            "snapshotManifestSHA256": pointer["sha256"],
            "researchAsOf": research["report"]["research_as_of"],
            "financialPeriodStart": research["report"]["coverage"]["start"],
            "financialPeriodEnd": research["report"]["coverage"]["end"],
            "physicalPageNumbering": "one-based",
            "documents": documents,
            "datasets": [{"file": path.name, "sha256": digest(path), "bytes": path.stat().st_size} for path in datasets],
            "pageReferences": references,
            "counts": {key: len(research[key]) for key in ("conclusions", "facts", "calculations", "evidence")},
        })
        if read_json(case / "published/research/current.json") != pointer:
            raise ValueError("Current publication changed before replacement; retry")
        if resources.exists():
            resources.rename(backup)
        try:
            stage.rename(resources)
        except BaseException:
            if backup.exists():
                backup.rename(resources)
            raise
        if backup.exists():
            shutil.rmtree(backup)
    finally:
        if stage.exists():
            shutil.rmtree(stage)
    return {
        "resources": str(resources), "snapshotId": pointer["snapshot_id"],
        "researchAsOf": research["report"]["research_as_of"],
        "documents": len(documents), "pageReferences": references,
        "conclusions": len(research["conclusions"]), "facts": len(research["facts"]),
        "calculations": len(research["calculations"]),
        "originalPDFBytes": sum(report["bytes"] for report in documents),
        "researchBytesUnchanged": True,
        "compiledReading": "reading.json" in snapshot["files"],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", type=Path, required=True, help="Existing company case directory; read-only")
    args = parser.parse_args()
    print(json.dumps(prepare(args.case), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
