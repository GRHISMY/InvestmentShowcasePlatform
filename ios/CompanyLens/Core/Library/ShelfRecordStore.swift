import Foundation
import Observation

/// Personal records have a separate workflow from publication preparation.
/// It owns acceptance, local ordering and the provider exchange, never content semantics.
@MainActor @Observable
final class ShelfRecordStore {
    private(set) var state = ShelfRecordState()
    var continuations: [ShelfContinuationChoice] { records.continuations }
    var onAccessFailure: ((Error) -> Void)?
    private let localRoot: URL
    private let deviceID: String
    private let cloud: any CloudFolder
    private var records: ShelfRecords
    private var savedRecordSequence: UInt64 = 0
    private var recordWriteTask: Task<Void, Never>?
    private var cloudRecordTask: Task<Void, Never>?
    private var cloudAcceptedSequence: UInt64 = 0
    private var hasAccess = false
    private var refreshIntent: UUID?
    private var accessEpoch = UUID()
    private var receiving = false
    private var receiveIssue: String?
    private var sendIssue: String?

    init(localRoot: URL, deviceID: String, cloud: any CloudFolder) {
        self.localRoot = localRoot
        self.deviceID = deviceID
        self.cloud = cloud
        records = ShelfRecords(deviceID: deviceID)
        do {
            if let own = try ShelfRecordDisk.load(deviceID: deviceID, root: localRoot) {
                records.restoreOwn(own)
                savedRecordSequence = own.sequence
            }
        } catch { state.local = .unsaved(error.localizedDescription) }
        if let received = try? ShelfRecordDisk.loadReceived(root: localRoot) {
            for record in received { _ = records.receive(record) }
        }
    }

    func restoration(for identity: StudyIdentity, preferred: ShelfContinuationChoice? = nil) -> RestoreCandidates {
        records.restoration(for: identity, preferred: preferred)
    }

    func mainCheckpoint(for choice: ShelfContinuationChoice) -> ReadingSlotCheckpoint? {
        records.mainCheckpoint(for: choice)
    }

    func setConnected(_ available: Bool) {
        refreshIntent = nil
        receiving = false
        receiveIssue = nil
        sendIssue = nil
        accessEpoch = UUID()
        cloudAcceptedSequence = 0
        hasAccess = available
        scheduleCloudExchange()
    }

    func acceptCheckpoint(_ checkpoint: ReadingCheckpoint) {
        guard records.accept(checkpoint) else { return }
        state.local = .saving
        scheduleRecordSave()
        updateCloudState()
    }

    func retryRecords() async {
        scheduleRecordSave()
        await recordWriteTask?.value
        await refresh()
        scheduleCloudExchange()
        while let pending = cloudRecordTask { await pending.value }
    }

    func refresh() async {
        guard hasAccess else { return }
        let intent = UUID()
        refreshIntent = intent
        receiving = true
        updateCloudState()
        defer {
            if refreshIntent == intent {
                receiving = false
                updateCloudState()
            }
        }
        let candidate = localRoot.appendingPathComponent("staging/records-" + UUID().uuidString)
        var failure: String?
        do {
            try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: candidate) }
            let paths = try await cloud.listRecordFiles()
            guard refreshIntent == intent else { return }
            for path in paths {
                do {
                    let components = try ShelfPath.parts(path)
                    guard components.count == 2, components[0] == "records", components[1].hasSuffix(".json") else {
                        throw CloudFolderError.invalidPath(path)
                    }
                    let otherDevice = String(components[1].dropLast(5))
                    guard !otherDevice.isEmpty else { throw CloudFolderError.invalidPath(path) }
                    let local = candidate.appendingPathComponent(UUID().uuidString + ".json")
                    try await cloud.copyFile(relativePath: path, to: local)
                    guard refreshIntent == intent else { return }
                    let received = try ShelfRecords.decode(Data(contentsOf: local), expectedDeviceID: otherDevice)
                    _ = records.receive(received)
                    if otherDevice != deviceID { try await ShelfRecordDisk.saveReceived(received, root: localRoot) }
                    else { scheduleRecordSave() }
                } catch {
                    guard refreshIntent == intent else { return }
                    failure = failure ?? error.localizedDescription
                    reportAccessFailure(error)
                }
            }
        } catch {
            guard refreshIntent == intent else { return }
            failure = error.localizedDescription
            reportAccessFailure(error)
        }
        guard refreshIntent == intent else { return }
        receiveIssue = failure
        await recordWriteTask?.value
    }

    private func scheduleRecordSave() {
        guard recordWriteTask == nil, let own = records.ownFile, own.sequence > savedRecordSequence else { return }
        recordWriteTask = Task { await savePendingRecords() }
    }

    private func savePendingRecords() async {
        defer {
            recordWriteTask = nil
            scheduleCloudExchange()
        }
        while let own = records.ownFile, own.sequence > savedRecordSequence {
            state.local = .saving
            do {
                try await ShelfRecordDisk.save(own, root: localRoot)
                savedRecordSequence = own.sequence
                if records.ownFile?.sequence == savedRecordSequence { state.local = .saved }
            } catch {
                state.local = .unsaved(error.localizedDescription)
                return
            }
        }
    }

    private func scheduleCloudExchange() {
        defer { updateCloudState() }
        guard hasAccess, let own = records.ownFile, own.sequence > cloudAcceptedSequence,
              own.sequence <= savedRecordSequence, cloudRecordTask == nil else { return }
        cloudRecordTask = Task { await sendPendingRecords() }
    }

    private func sendPendingRecords() async {
        let epoch = accessEpoch
        sendIssue = nil
        updateCloudState()
        defer {
            cloudRecordTask = nil
            if epoch != accessEpoch { scheduleCloudExchange() }
            else { updateCloudState() }
        }
        while hasAccess, epoch == accessEpoch, let own = records.ownFile, own.sequence > cloudAcceptedSequence {
            guard own.sequence <= savedRecordSequence else { return }
            do {
                let bytes = try JSONEncoder().encode(own)
                try await cloud.replaceOwnRecord(deviceID: deviceID, contents: bytes)
                guard epoch == accessEpoch else { return }
                cloudAcceptedSequence = own.sequence
            } catch {
                guard epoch == accessEpoch else { return }
                sendIssue = error.localizedDescription
                reportAccessFailure(error)
                return
            }
        }
    }

    private func reportAccessFailure(_ error: Error) {
        if let failure = error as? CloudFolderError, failure == .needsSelection { onAccessFailure?(error) }
    }

    private func updateCloudState() {
        if !hasAccess { state.cloud = .waitingForConnection }
        else if let issue = receiveIssue ?? sendIssue { state.cloud = .failed(issue) }
        else if receiving || cloudRecordTask != nil { state.cloud = .exchanging }
        else if let own = records.ownFile, own.sequence > cloudAcceptedSequence { state.cloud = .pending }
        else { state.cloud = .accepted }
    }
}
