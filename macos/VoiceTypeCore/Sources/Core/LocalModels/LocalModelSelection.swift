import Foundation

public enum LocalModelStatus: Equatable, Sendable {
    case notDownloaded, downloaded, downloading(Double), preparing, ready, failed(String)
}

// One load of one model. The generation is unique across all attempts, so a late
// result from a cancelled attempt never matches a newer attempt of the same model.
public struct LoadAttempt: Hashable, Sendable {
    public let modelID: String
    public let generation: Int
}

public enum LocalModelEffect: Equatable, Sendable {
    case load(LoadAttempt), cancelLoad(LoadAttempt), unload(String), deleteFiles(String), persistSelection(String)
}

// Pure model-switching logic: which model is active, which one is loading, and what
// the app must do (effects) on each event. The previous active model keeps serving
// until the pending one succeeds; a failed or cancelled attempt reverts to it, or to
// the default model at boot when nothing is active yet.
public struct LocalModelSelection: Equatable, Sendable {
    public private(set) var active: String?
    public private(set) var pendingAttempt: LoadAttempt?
    public var pending: String? { pendingAttempt?.modelID }
    public var selected: String { pending ?? active ?? LocalModelCatalog.defaultID }

    private let modelIDs: [String]
    private var nextGeneration = 1
    private var downloaded: Set<String>
    private var progress: [String: LocalModelStatus] = [:]
    private var failures: [String: String] = [:]
    // Models whose load was under way when the app last died; no automatic
    // fallback loads them, only picking them again does.
    private var crashed: Set<String> = []
    // Whether the pending model's files were complete before its attempt started;
    // a cancelled download only deletes what it fetched itself.
    private var pendingWasDownloaded = false

    public init(modelIDs: [String], downloaded: Set<String>) {
        self.modelIDs = modelIDs
        self.downloaded = downloaded
    }

    public func status(of id: String) -> LocalModelStatus {
        if id == pending, let status = progress[id] { return status }
        if let message = failures[id] { return .failed(message) }
        if id == active { return .ready }
        if downloaded.contains(id) { return .downloaded }
        return .notDownloaded
    }

    /// Whether the model's complete files are on disk, failed or not.
    public func hasFiles(_ id: String) -> Bool { downloaded.contains(id) }

    /// The app died while `id` was loading: Core ML crashes on damaged weights
    /// instead of throwing. Call before `boot`; the row shows `message`.
    public mutating func recordCrash(_ id: String, message: String) {
        guard modelIDs.contains(id) else { return }
        crashed.insert(id)
        failures[id] = message
    }

    public mutating func boot(selectedID: String) -> [LocalModelEffect] {
        guard active == nil, pendingAttempt == nil else { return [] }
        let defaultID = LocalModelCatalog.defaultID
        // A model that crashed the app is only loaded again when picked, or
        // every launch would crash; the default takes its place.
        let candidates = modelIDs.contains(selectedID) ? [selectedID, defaultID] : [defaultID]
        let target = candidates.first { !crashed.contains($0) }
        let persist: [LocalModelEffect] = (target ?? defaultID) == selectedID ? [] : [.persistSelection(defaultID)]
        guard let target else { return persist }
        return [.load(startLoad(target))] + persist
    }

    public mutating func select(_ id: String) -> [LocalModelEffect] {
        guard modelIDs.contains(id), id != pending else { return [] }
        if id == active {
            // Picking the model in use again while another one loads means going back.
            return cancel()
        }
        var effects = endPendingByCancel()
        crashed.remove(id)
        effects += [.load(startLoad(id)), .persistSelection(id)]
        return effects
    }

    public mutating func progress(_ attempt: LoadAttempt, _ status: LocalModelStatus) {
        guard attempt == pendingAttempt else { return }
        progress[attempt.modelID] = status
    }

    public mutating func loadSucceeded(_ attempt: LoadAttempt) -> [LocalModelEffect] {
        guard attempt == pendingAttempt else { return [] }
        let id = attempt.modelID
        let previous = active
        clearPending()
        active = id
        downloaded.insert(id)
        failures[id] = nil
        guard let previous, previous != id else { return [] }
        return [.unload(previous)]
    }

    public mutating func loadFailed(_ attempt: LoadAttempt, message: String) -> [LocalModelEffect] {
        guard attempt == pendingAttempt else { return [] }
        let id = attempt.modelID
        let wasDownloaded = pendingWasDownloaded
        clearPending()
        failures[id] = message
        // A failure is no proof the files are bad (offline, the repository is
        // down): complete files stay, and a retry loads them again. Only an
        // incomplete download is cleaned up, as on cancel.
        let cleanup: [LocalModelEffect] = wasDownloaded ? [] : [.deleteFiles(id)]
        return cleanup + revert(after: id)
    }

    public mutating func cancel() -> [LocalModelEffect] {
        guard let id = pending else { return [] }
        return endPendingByCancel() + revert(after: id)
    }

    public mutating func delete(_ id: String) -> [LocalModelEffect] {
        guard id != active, id != pending, downloaded.contains(id) else { return [] }
        downloaded.remove(id)
        failures[id] = nil
        return [.deleteFiles(id)]
    }

    private mutating func startLoad(_ id: String) -> LoadAttempt {
        let attempt = LoadAttempt(modelID: id, generation: nextGeneration)
        nextGeneration += 1
        pendingAttempt = attempt
        pendingWasDownloaded = downloaded.contains(id)
        failures[id] = nil
        progress[id] = pendingWasDownloaded ? .preparing : .downloading(0)
        return attempt
    }

    private mutating func clearPending() {
        if let id = pending { progress[id] = nil }
        pendingAttempt = nil
        pendingWasDownloaded = false
    }

    private mutating func endPendingByCancel() -> [LocalModelEffect] {
        guard let attempt = pendingAttempt else { return [] }
        let wasDownloaded = pendingWasDownloaded
        clearPending()
        return wasDownloaded ? [.cancelLoad(attempt)] : [.cancelLoad(attempt), .deleteFiles(attempt.modelID)]
    }

    // After the pending attempt ends without success: go back to the active model, or,
    // at boot, load the default — unless the attempt that ended was the default itself,
    // or the default is the one that crashed the app (its failure stays on its row).
    private mutating func revert(after id: String) -> [LocalModelEffect] {
        if let active { return [.persistSelection(active)] }
        let defaultID = LocalModelCatalog.defaultID
        guard id != defaultID else { return [] }
        guard !crashed.contains(defaultID) else { return [.persistSelection(defaultID)] }
        return [.persistSelection(defaultID), .load(startLoad(defaultID))]
    }
}
