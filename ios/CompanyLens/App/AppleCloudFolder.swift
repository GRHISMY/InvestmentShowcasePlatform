import Foundation
import FileProvider
#if SWIFT_PACKAGE
import ResearchCore
#endif

/// Coordinates bytes and the selected directory grant; publication policy stays in StudyShelf.
actor AppleCloudFolder: CloudFolder {
    private let ownDeviceID: String
    private var directory: URL?
    private var ownsGrant = false
    init(ownDeviceID: String) { self.ownDeviceID = ownDeviceID }

    static func bookmark(for directory: URL) throws -> Data {
        let accessed = directory.startAccessingSecurityScopedResource()
        defer { if accessed { directory.stopAccessingSecurityScopedResource() } }
        #if os(macOS)
        return try directory.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        return try directory.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }

    deinit { if ownsGrant { directory?.stopAccessingSecurityScopedResource() } }

    func restoreAccess(bookmark: Data) async throws -> CloudFolderAccess {
        var stale = false
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
        #else
        let options: URL.BookmarkResolutionOptions = [.withoutUI]
        #endif
        let candidate: URL
        do {
            candidate = try URL(resolvingBookmarkData: bookmark, options: options,
                                relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch { throw Self.accessFailure(error, decodingBookmark: true) }
        guard candidate.isFileURL else { throw CloudFolderError.needsSelection }
        let granted = candidate.startAccessingSecurityScopedResource()
        do {
            try Self.requireDirectory(candidate)
            let replacement = stale ? try Self.bookmark(for: candidate) : nil
            if ownsGrant { directory?.stopAccessingSecurityScopedResource() }
            directory = candidate.standardizedFileURL
            ownsGrant = granted
            return CloudFolderAccess(replacementBookmark: replacement)
        } catch {
            if granted { candidate.stopAccessingSecurityScopedResource() }
            throw Self.accessFailure(error)
        }
    }

    /// Provider reachability or credentials do not prove that the selected URL's grant was lost.
    private static func accessFailure(_ error: Error, decodingBookmark: Bool = false) -> CloudFolderError {
        if let error = error as? CloudFolderError { return error }
        var errors: [NSError] = [], current: NSError? = error as NSError
        var seen = Set<ObjectIdentifier>()
        while let value = current, seen.insert(ObjectIdentifier(value)).inserted {
            errors.append(value)
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        if errors.contains(where: { $0.domain == NSFileProviderErrorDomain }) {
            return .unavailable(error.localizedDescription)
        }
        if errors.contains(where: { value in
            (value.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(value.code))
                || (value.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(value.code))
        }) { return .needsSelection }
        if decodingBookmark, errors.contains(where: { $0.domain == NSCocoaErrorDomain && $0.code == NSFileReadCorruptFileError }) {
            return .needsSelection
        }
        return .unavailable(error.localizedDescription)
    }

    private static func requireDirectory(_ url: URL) throws {
        guard let isDirectory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory else {
            throw CloudFolderError.unavailable("系统暂时无法确认研究目录。")
        }
        guard isDirectory else { throw CloudFolderError.needsSelection }
    }

    private func selectedDirectory() throws -> URL {
        guard let directory else { throw CloudFolderError.needsSelection }
        do { try Self.requireDirectory(directory) }
        catch { throw Self.accessFailure(error) }
        return directory
    }

    func copyFile(relativePath: String, to localURL: URL) async throws {
        let directory = try selectedDirectory()
        let source = try containedURL(relativePath, directory: directory)
        if (try? source.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true {
            do { try FileManager.default.startDownloadingUbiquitousItem(at: source) }
            catch { throw Self.accessFailure(error) }
        }
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var result: Result<Void, Error>?
        coordinator.coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { coordinatedURL in
            result = Result {
                try Self.requireContained(coordinatedURL, in: directory, relativePath: relativePath)
                try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: coordinatedURL, to: localURL)
            }
        }
        if let coordinationError { throw Self.accessFailure(coordinationError) }
        guard let result else { throw CloudFolderError.unavailable("系统尚未提供文件。") }
        do { try result.get() }
        catch { throw Self.accessFailure(error) }
    }
    private func containedURL(_ path: String, directory: URL) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.contains("\\"), !path.contains("\0"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw CloudFolderError.invalidPath(path)
        }
        let result = directory.appendingPathComponent(path)
        try Self.requireContained(result, in: directory, relativePath: path)
        return result
    }

    private static func requireContained(_ url: URL, in directory: URL, relativePath: String) throws {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path
        guard url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root + "/") else {
            throw CloudFolderError.invalidPath(relativePath)
        }
    }

    func listRecordFiles() async throws -> [String] {
        let directory = try selectedDirectory()
        let records = try containedURL("records", directory: directory)
        do {
            _ = try records.resourceValues(forKeys: [.isDirectoryKey])
        } catch {
            let value = error as NSError
            if (value.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(value.code))
                || (value.domain == NSPOSIXErrorDomain && value.code == Int(ENOENT))
                || (value.domain == NSFileProviderErrorDomain && value.code == NSFileProviderError.Code.noSuchItem.rawValue) {
                return []
            }
            throw Self.accessFailure(error)
        }
        var coordinationError: NSError?
        var result: Result<[String], Error>?
        NSFileCoordinator().coordinate(readingItemAt: records, options: .withoutChanges, error: &coordinationError) { url in
            result = Result {
                try Self.requireContained(url, in: directory, relativePath: "records")
                return try FileManager.default.contentsOfDirectory(at: url,
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]).compactMap { file in
                    let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard file.pathExtension == "json", values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
                    return "records/" + file.lastPathComponent
                }.sorted()
            }
        }
        if let coordinationError { throw Self.accessFailure(coordinationError) }
        guard let result else { throw CloudFolderError.unavailable("系统尚未提供阅读记录。") }
        do { return try result.get() }
        catch { throw Self.accessFailure(error) }
    }

    func replaceOwnRecord(deviceID: String, contents: Data) async throws {
        guard deviceID == ownDeviceID, !deviceID.isEmpty,
              deviceID.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }) else {
            throw CloudFolderError.invalidPath(deviceID)
        }
        let directory = try selectedDirectory()
        let records = try containedURL("records", directory: directory)
        var coordinationError: NSError?
        var result: Result<Void, Error>?
        NSFileCoordinator().coordinate(writingItemAt: records, options: .forMerging, error: &coordinationError) { url in
            result = Result {
                try Self.requireContained(url, in: directory, relativePath: "records")
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                let target = url.appendingPathComponent(deviceID + ".json")
                try Self.requireContained(target, in: directory, relativePath: "records/" + deviceID)
                try contents.write(to: target, options: .atomic)
            }
        }
        if let coordinationError { throw Self.accessFailure(coordinationError) }
        guard let result else { throw CloudFolderError.unavailable("系统尚未接收阅读记录。") }
        do { try result.get() }
        catch { throw Self.accessFailure(error) }
    }
}
