import Foundation

/// Transport and directory permission only. No publication or reading policy lives here.
public protocol CloudFolder {
    func restoreAccess(bookmark: Data) async throws -> CloudFolderAccess
    func copyFile(relativePath: String, to localURL: URL) async throws
    func listRecordFiles() async throws -> [String]
    func replaceOwnRecord(deviceID: String, contents: Data) async throws
}

public struct CloudFolderAccess {
    public let replacementBookmark: Data?
    public init(replacementBookmark: Data? = nil) { self.replacementBookmark = replacementBookmark }
}

public enum CloudFolderError: Error, Equatable, LocalizedError {
    case needsSelection
    case unavailable(String)
    case missingFile(String)
    case invalidPath(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .needsSelection: return "请重新选择专用研究目录。"
        case .unavailable(let reason): return "资料暂时无法从 iCloud 取得：" + reason
        case .missingFile(let file): return "研究目录中暂时缺少文件：" + file
        case .invalidPath: return "研究目录包含无法使用的文件路径。"
        case .cancelled: return "已取消取得资料。"
        }
    }
}
