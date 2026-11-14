import Foundation
import XCTest

final class CloudFolderHostTests: XCTestCase {
    func testCorruptBookmarkRequiresAReplacementSelection() async throws {
        let folder = AppleCloudFolder(ownDeviceID: "device-a")
        for bookmark in [Data(), Data("not a system bookmark".utf8)] {
            do {
                _ = try await folder.restoreAccess(bookmark: bookmark)
                XCTFail("corrupt bookmark data cannot restore a selected directory")
            } catch CloudFolderError.needsSelection { }
            catch { XCTFail("invalid bookmark data needs a replacement selection: \(error)") }
        }
    }

    func testConfirmedDirectoryPermissionLossIsNotReportedAsTemporaryCloudAvailability() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let selected = root.appendingPathComponent("selected")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: selected.path)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        let source = selected.appendingPathComponent("catalog.json")
        try Data("selected publication".utf8).write(to: source)
        let bookmark = try AppleCloudFolder.bookmark(for: selected)
        let folder = AppleCloudFolder(ownDeviceID: "device-a")
        _ = try await folder.restoreAccess(bookmark: bookmark)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: selected.path)
        guard !FileManager.default.isReadableFile(atPath: source.path) else {
            throw XCTSkip("this runtime does not enforce the fixture's directory access denial")
        }
        do {
            try await folder.copyFile(relativePath: "catalog.json", to: root.appendingPathComponent("blocked.json"))
            XCTFail("a directory without search permission cannot provide the selected publication")
        } catch CloudFolderError.needsSelection { }
        catch { XCTFail("a confirmed filesystem permission loss needs an accessible selection: \(error)") }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: selected.path)
        _ = try await folder.restoreAccess(bookmark: bookmark)
        let local = root.appendingPathComponent("recovered.json")
        try await folder.copyFile(relativePath: "catalog.json", to: local)
        XCTAssertEqual(try Data(contentsOf: local), Data("selected publication".utf8))
    }

    func testRecordExchangeDistinguishesAnUncreatedDirectoryFromLostAccess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let selected = root.appendingPathComponent("selected")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: selected.path)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        let folder = AppleCloudFolder(ownDeviceID: "device-a")
        _ = try await folder.restoreAccess(bookmark: AppleCloudFolder.bookmark(for: selected))
        let empty = try await folder.listRecordFiles()
        XCTAssertEqual(empty, [])
        let records = selected.appendingPathComponent("records")
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        try Data("other device".utf8).write(to: records.appendingPathComponent("device-b.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: selected.path)
        guard !FileManager.default.isReadableFile(atPath: records.path) else {
            throw XCTSkip("this runtime does not enforce the fixture's directory access denial")
        }
        do {
            _ = try await folder.listRecordFiles()
            XCTFail("lost access cannot silently appear as an empty record directory")
        } catch CloudFolderError.needsSelection { }
        catch { XCTFail("listing a denied selected directory requires an accessible selection: \(error)") }
        do {
            try await folder.replaceOwnRecord(deviceID: "device-a", contents: Data("own device".utf8))
            XCTFail("lost access cannot accept a new device record")
        } catch CloudFolderError.needsSelection { }
        catch { XCTFail("writing a denied selected directory requires an accessible selection: \(error)") }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: selected.path)
        let recovered = try await folder.listRecordFiles()
        XCTAssertEqual(recovered, ["records/device-b.json"])
    }

    func testTemporarilyUnavailableSelectedDirectoryIsNotRecreatedByRecordExchange() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appendingPathComponent("selected")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        let folder = AppleCloudFolder(ownDeviceID: "device-a")
        _ = try await folder.restoreAccess(bookmark: AppleCloudFolder.bookmark(for: selected))
        try FileManager.default.removeItem(at: selected)
        var failures: [String] = []
        do {
            _ = try await folder.listRecordFiles()
            failures.append("a missing selected directory was reported as an empty record directory")
        } catch CloudFolderError.unavailable { }
        catch { failures.append("unexpected list failure: \(error)") }
        do {
            try await folder.replaceOwnRecord(deviceID: "device-a", contents: Data("own record".utf8))
            failures.append("a missing selected directory accepted a record write")
        } catch CloudFolderError.unavailable { }
        catch { failures.append("unexpected write failure: \(error)") }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "; "))
        XCTAssertFalse(FileManager.default.fileExists(atPath: selected.path),
                       "record exchange may create records inside a valid selection, but cannot recreate that selection")
    }

    func testTemporarilyUnavailableBookmarkedDirectoryCanBeRetriedWithoutSelectingAgain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appendingPathComponent("selected")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        let bookmark = try AppleCloudFolder.bookmark(for: selected)
        let folder = AppleCloudFolder(ownDeviceID: "device-a")
        _ = try await folder.restoreAccess(bookmark: bookmark)
        try FileManager.default.removeItem(at: selected)
        do {
            _ = try await folder.restoreAccess(bookmark: bookmark)
            XCTFail("unavailable directory metadata cannot establish an accessible directory")
        } catch CloudFolderError.unavailable { }
        catch { XCTFail("a valid bookmark with temporarily unavailable metadata must remain retryable: \(error)") }
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        try Data("returned catalog".utf8).write(to: selected.appendingPathComponent("catalog.json"))
        _ = try await folder.restoreAccess(bookmark: bookmark)
        let local = root.appendingPathComponent("local/catalog.json")
        try await folder.copyFile(relativePath: "catalog.json", to: local)
        XCTAssertEqual(try Data(contentsOf: local), Data("returned catalog".utf8))
    }

    func testTransportRefusesToWriteAnyDeviceOtherThanItsOwn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let folder = AppleCloudFolder(ownDeviceID: "device-a")
        _ = try await folder.restoreAccess(bookmark: AppleCloudFolder.bookmark(for: root))
        for id in ["device-b", "../escape"] {
            do {
                try await folder.replaceOwnRecord(deviceID: id, contents: Data("wrong writer".utf8))
                XCTFail("transport must own exactly its device file")
            } catch CloudFolderError.invalidPath { }
            catch { XCTFail("wrong device must be refused explicitly") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("records/device-b.json").path))
    }

    func testOwnRecordCanBeReplacedWithoutChangingAnotherDevicesRecord() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let records = root.appendingPathComponent("records")
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        let other = records.appendingPathComponent("device-b.json")
        try Data("other device".utf8).write(to: other)
        let folder = AppleCloudFolder(ownDeviceID: "device-a")
        _ = try await folder.restoreAccess(bookmark: AppleCloudFolder.bookmark(for: root))
        try await folder.replaceOwnRecord(deviceID: "device-a", contents: Data("first".utf8))
        try await folder.replaceOwnRecord(deviceID: "device-a", contents: Data("latest".utf8))
        let files = try await folder.listRecordFiles()
        XCTAssertEqual(Set(files), ["records/device-a.json", "records/device-b.json"])
        XCTAssertEqual(try Data(contentsOf: other), Data("other device".utf8))
        let local = root.appendingPathComponent("local-copy.json")
        try await folder.copyFile(relativePath: "records/device-a.json", to: local)
        XCTAssertEqual(try Data(contentsOf: local), Data("latest".utf8))
    }

    func testSelectedFolderDoesNotGrantAccessToTraversalOrSymlinkTargetsOutsideIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cloud = root.appendingPathComponent("selected")
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        let secret = root.appendingPathComponent("secret.json")
        try Data("outside selection".utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(at: cloud.appendingPathComponent("escape.json"), withDestinationURL: secret)
        let folder = AppleCloudFolder(ownDeviceID: "device-a")
        _ = try await folder.restoreAccess(bookmark: AppleCloudFolder.bookmark(for: cloud))
        for path in ["../secret.json", secret.path, "escape.json"] {
            do {
                try await folder.copyFile(relativePath: path, to: root.appendingPathComponent(UUID().uuidString))
                XCTFail("selected directory must not permit " + path)
            } catch CloudFolderError.invalidPath { }
            catch { XCTFail("unsafe paths need an explicit invalidPath result: \(error)") }
        }
    }

    func testSelectedFolderCanBeRestoredAndAFileCopiedIntoAnIndependentLocalDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cloud = root.appendingPathComponent("selected")
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        try Data("published catalog".utf8).write(to: cloud.appendingPathComponent("catalog.json"))
        let local = root.appendingPathComponent("private-stage/catalog.json")
        let folder: any CloudFolder = AppleCloudFolder(ownDeviceID: "device-a")
        _ = try await folder.restoreAccess(bookmark: AppleCloudFolder.bookmark(for: cloud))
        try await folder.copyFile(relativePath: "catalog.json", to: local)
        XCTAssertEqual(try Data(contentsOf: local), Data("published catalog".utf8))
        try Data("changed later".utf8).write(to: cloud.appendingPathComponent("catalog.json"))
        XCTAssertEqual(try Data(contentsOf: local), Data("published catalog".utf8))
    }
}
