import Foundation

public enum ShelfLocalRecordState: Equatable {
    case saved
    case saving
    case unsaved(String)
}

public enum ShelfCloudRecordState: Equatable {
    case waitingForConnection
    case pending
    case exchanging
    /// The known directory exchange finished locally; remote delivery is not proven.
    case accepted
    case failed(String)
}

public struct ShelfRecordState: Equatable {
    public internal(set) var local: ShelfLocalRecordState = .saved
    public internal(set) var cloud: ShelfCloudRecordState = .waitingForConnection
}
