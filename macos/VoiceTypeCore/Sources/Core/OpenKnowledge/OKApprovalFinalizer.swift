import Foundation

/// Brings the meeting's local state in line with a transaction the vault
/// already holds. Until `OKVaultWriter.finish` deletes the `committed`
/// journal, the journal is the proof the vault was written, so every step is
/// idempotent and can run again from any point (the bootstrap calls it after
/// `recover`). Runs entirely inside `MeetingProposalStore.withLock`.
public enum OKApprovalFinalizer {
    /// 1. the fixed paths go into `pipeline.json`; 2. the proposal of the
    /// receipt's generation goes away (a newer one stays); 3. `finish`.
    /// Returns what `finish` preserved.
    @discardableResult
    public static func finalize(meetingDirectory: URL, receipt: OKCommitReceipt, fileManager: FileManager = .default) throws -> [OKDivergence] {
        try MeetingProposalStore.withLock {
            try recordFixedPaths(receipt, in: meetingDirectory)
            if MeetingProposalStore.load(meetingDirectory)?.generation == receipt.proposalGeneration {
                try removeProposal(meetingDirectory, fileManager)
            }
            return try OKVaultWriter.finish(journalDirectory: journalDirectory(meetingDirectory))
        }
    }

    /// A `.partial` result: the record and transcript are in the vault and
    /// only the conflicting items go back to review. The proposal of the
    /// receipt's generation keeps its generation, with the paths fixed,
    /// `recordWritten`, the current hashes and only the conflicting items
    /// (as updates of what's now in the vault); the progress restarts at the
    /// first pending step. Nothing left to review → removed, as in `finalize`.
    @discardableResult
    public static func finalizePartial(
        meetingDirectory: URL, receipt: OKCommitReceipt, conflicts: [OKConflict], fileManager: FileManager = .default
    ) throws -> [OKDivergence] {
        try MeetingProposalStore.withLock {
            try recordFixedPaths(receipt, in: meetingDirectory)
            if var p = MeetingProposalStore.load(meetingDirectory), p.generation == receipt.proposalGeneration {
                let vault = URL(fileURLWithPath: receipt.vault.root, isDirectory: true)
                p.project = receipt.project
                p.fixedPaths = receipt.paths
                p.paths = receipt.paths
                p.recordWritten = true
                p.existingRecordHash = OKApprovalSession.hash(of: receipt.paths.record, in: vault)
                p.existingTranscriptHash = OKApprovalSession.hash(of: receipt.paths.transcript, in: vault)
                p.existingRecordContent = nil
                let ids = Set(conflicts.compactMap(\.itemID))
                p.items = p.items.filter { ids.contains($0.id) }
                let recordConflict = p.absorb(conflicts)
                if p.items.isEmpty && !recordConflict {
                    try removeProposal(meetingDirectory, fileManager)
                } else {
                    try MeetingProposalStore.save(p, in: meetingDirectory)
                    var session = OKApprovalSession(proposal: p, progress: nil)
                    session.moveToFirstPending()
                    try session.progress.save(in: meetingDirectory)
                }
            }
            return try OKVaultWriter.finish(journalDirectory: journalDirectory(meetingDirectory))
        }
    }

    // MARK: - Helpers

    private static func journalDirectory(_ dir: URL) -> URL {
        dir.appendingPathComponent(MeetingProposalStore.journalFolder, isDirectory: true)
    }

    /// Over the `pipeline.json` read back from disk; one that exists but
    /// can't be read throws instead of being replaced.
    private static func recordFixedPaths(_ receipt: OKCommitReceipt, in dir: URL) throws {
        let url = dir.appendingPathComponent(MeetingPipelineState.stateFileName)
        var state = FileManager.default.fileExists(atPath: url.path)
            ? try JSONDecoder().decode(MeetingPipelineState.self, from: Data(contentsOf: url))
            : MeetingPipelineState(noteID: receipt.meetingID)
        state.okVault = receipt.vault
        state.okProject = receipt.project
        state.okRecordPath = receipt.paths.record
        state.okTranscriptPath = receipt.paths.transcript
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
    }

    /// The proposal and the window's progress; a failure throws, so the
    /// journal stays and the next run tries again.
    private static func removeProposal(_ dir: URL, _ fileManager: FileManager) throws {
        for name in [MeetingProposal.fileName, OKApprovalProgress.fileName] {
            do {
                try fileManager.removeItem(at: dir.appendingPathComponent(name))
            } catch CocoaError.fileNoSuchFile {}
        }
    }
}
