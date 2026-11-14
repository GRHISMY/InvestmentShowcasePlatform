"""Distribute an existing immutable research publication to a study library."""
import argparse
from datetime import date
import fcntl
import json
import os
from pathlib import Path
import shutil
import tempfile

import prepare_resources as packaging


def _file_inventory(root):
    result = {}
    for path in root.rglob("*"):
        if path.is_symlink():
            raise ValueError("Existing version contains a symbolic link: " + str(path))
        if path.is_file():
            result[str(path.relative_to(root))] = packaging.digest(path)
    return result


def _safe_destination(root, relative):
    if not relative or "\\" in relative or any(part in {"", ".", ".."} for part in relative.split("/")):
        raise ValueError("Invalid library-relative path: " + relative)
    target = root
    for part in relative.split("/"):
        target = target / part
        if target.is_symlink():
            raise ValueError("Library path must not be a symbolic link: " + str(target))
    return target


def _validate_metadata(company, version):
    if (not isinstance(company["id"], str) or not packaging.SAFE_ID.fullmatch(company["id"])
            or not isinstance(company["name"], str) or not company["name"].strip()
            or any(not isinstance(company[key], str) for key in ("code", "exchange"))):
        raise ValueError("invalid company")
    if (not isinstance(version["reportId"], str) or not version["reportId"].strip()
            or type(version["reportRevision"]) is not int or version["reportRevision"] < 1):
        raise ValueError("invalid report identity or revision")
    for key in ("researchAsOf", "financialPeriodStart", "financialPeriodEnd"):
        value = version[key]
        if not isinstance(value, str) or date.fromisoformat(value).isoformat() != value:
            raise ValueError("invalid report date")


def _read_catalog(path, library):
    if not path.exists():
        return {"schemaVersion": 1, "companies": []}
    try:
        catalog = packaging.read_json(path)
        if type(catalog["schemaVersion"]) is not int or catalog["schemaVersion"] != 1 or not isinstance(catalog["companies"], list):
            raise ValueError("unsupported schema")
        company_ids = set()
        for entry in catalog["companies"]:
            company_id = entry["company"]["id"]
            if not isinstance(company_id, str) or not packaging.SAFE_ID.fullmatch(company_id) or company_id in company_ids:
                raise ValueError("invalid or duplicate company")
            company_ids.add(company_id)
            if not isinstance(entry["versions"], list) or not entry["versions"]:
                raise ValueError("missing versions")
            version_ids = set()
            for version in entry["versions"]:
                _validate_metadata(entry["company"], version)
                snapshot_id = version["snapshotId"]
                snapshot_sha = version["snapshotManifestSHA256"]
                resource_sha = version["resourceManifestSHA256"]
                if (not isinstance(snapshot_id, str) or not packaging.SAFE_ID.fullmatch(snapshot_id)
                        or not isinstance(snapshot_sha, str) or not packaging.SHA256.fullmatch(snapshot_sha)
                        or not isinstance(resource_sha, str) or not packaging.SHA256.fullmatch(resource_sha)):
                    raise ValueError("invalid version identity")
                version_id = snapshot_id + "--" + snapshot_sha
                relative = "packages/" + company_id + "/" + version_id
                if version["versionId"] != version_id or version_id in version_ids or version["packagePath"] != relative:
                    raise ValueError("duplicate or inconsistent version path")
                _safe_destination(library, relative)
                version_ids.add(version_id)
            if entry["currentVersionId"] not in version_ids:
                raise ValueError("current version is absent")
        return catalog
    except (ValueError, TypeError, KeyError) as error:
        raise ValueError("Invalid study catalog: " + str(error)) from error


def publish(case, library):
    """Publish the case's current formal snapshot without changing the case."""
    case = Path(case).expanduser().resolve(strict=True)
    library = Path(library).expanduser()
    if library.is_symlink():
        raise ValueError("Study library must not be a symbolic link")
    library = library.resolve()
    if library.is_relative_to(case) or case.is_relative_to(library):
        raise ValueError("The study library and read-only case must not overlap")
    library.mkdir(parents=True, exist_ok=True)
    lock_path = _safe_destination(library, ".publish.lock")
    with lock_path.open("a+b") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        return _publish_locked(case, library)


def _publish_locked(case, library):
    catalog_path = _safe_destination(library, "catalog.json")
    catalog = _read_catalog(catalog_path, library)
    with tempfile.TemporaryDirectory(prefix=".publish-stage-", dir=library) as temporary:
        package = Path(temporary) / "package"
        packaging.prepare(case, package)
        research = packaging.read_json(package / "research.json")
        snapshot = packaging.read_json(package / "snapshot.json")
        snapshot_sha = packaging.digest(package / "snapshot.json")
        pointer = packaging.read_json(case / "published/research/current.json")
        if (pointer.get("schema_version") != "cfa-research-current/v1"
                or snapshot.get("schema_version") != "cfa-research-snapshot/v1"
                or pointer.get("snapshot_id") != snapshot["snapshot_id"] or pointer.get("sha256") != snapshot_sha):
            raise ValueError("Unsupported or changed formal publication envelope; retry from a stable current snapshot")
        version_id = snapshot["snapshot_id"] + "--" + snapshot_sha
        try:
            source_company = research["company"]
            company = {key: source_company[key] for key in ("id", "name", "code")}
            company["exchange"] = source_company.get("exchange", "")
            report = research["report"]
            version = {
                "versionId": version_id, "snapshotId": snapshot["snapshot_id"],
                "snapshotManifestSHA256": snapshot_sha,
                "resourceManifestSHA256": packaging.digest(package / "resource-manifest.json"),
                "packagePath": "packages/" + company["id"] + "/" + version_id,
                "reportId": report["id"], "reportRevision": report["revision"],
                "financialPeriodStart": report["coverage"]["start"],
                "financialPeriodEnd": report["coverage"]["end"], "researchAsOf": report["research_as_of"],
            }
            _validate_metadata(company, version)
        except (KeyError, ValueError, TypeError) as error:
            raise ValueError("Invalid publication metadata: " + str(error)) from error
        relative = version["packagePath"]
        target = _safe_destination(library, relative)
        created = not target.exists()
        if not created and (not target.is_dir() or _file_inventory(target) != _file_inventory(package)):
            raise ValueError("Existing version differs from the verified publication: " + relative)
        entry = next((item for item in catalog["companies"] if item["company"]["id"] == company["id"]), None)
        if entry is None:
            catalog["companies"].append({"company": company, "currentVersionId": version_id, "versions": [version]})
        else:
            existing = next((item for item in entry["versions"] if item["versionId"] == version_id), None)
            if existing is not None and existing != version:
                raise ValueError("Existing version catalog metadata differs from the verified publication")
            if existing is None:
                entry["versions"].append(version)
                entry["currentVersionId"] = version_id
                entry["company"] = company
        catalog["companies"].sort(key=lambda item: item["company"]["id"])
        for item in catalog["companies"]:
            item["versions"].sort(key=lambda value: value["versionId"])
        catalog_stage = Path(temporary) / "catalog.json"
        packaging.write_json(catalog_stage, catalog)
        with catalog_stage.open("rb") as staged_file:
            os.fsync(staged_file.fileno())
        installed = False
        try:
            if created:
                target.parent.mkdir(parents=True, exist_ok=True)
                package.rename(target)
                installed = True
            if not catalog_path.exists() or catalog_path.read_bytes() != catalog_stage.read_bytes():
                os.replace(catalog_stage, catalog_path)
        except BaseException:
            if installed:
                # Replacement may have committed before its result was lost.
                # Remove only when a readable, valid catalog proves no reference.
                unreferenced = False
                try:
                    observed = _read_catalog(catalog_path, library)
                    unreferenced = not any(
                        version["packagePath"] == relative
                        for entry in observed["companies"] for version in entry["versions"]
                    )
                except Exception:
                    pass  # An uncertain outcome keeps the complete immutable package.
                if unreferenced:
                    shutil.rmtree(target)
            raise
    return {"catalog": str(library / "catalog.json"), "companyId": company["id"],
            "versionId": version_id, "packagePath": relative, "created": created}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", type=Path, required=True, help="Existing formal company case; read-only")
    parser.add_argument("--library", type=Path, required=True, help="Dedicated study library directory")
    args = parser.parse_args()
    try:
        result = publish(args.case, args.library)
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, "Publish failed: " + str(error) + "\n")
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
