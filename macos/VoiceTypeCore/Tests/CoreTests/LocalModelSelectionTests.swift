import Testing
@testable import Core

@Suite("LocalModelSelection")
struct LocalModelSelectionTests {
    let small = LocalModelCatalog.defaultID
    let turbo = "openai_whisper-large-v3-v20240930_turbo_632MB"
    let parakeet = "parakeet-ultra"
    var ids: [String] { [small, turbo, parakeet] }

    func attempt(in effects: [LocalModelEffect]) -> LoadAttempt? {
        for case .load(let attempt) in effects { return attempt }
        return nil
    }

    // Boots on `small` and lets it finish, so `small` is the active model.
    func activeSmall(downloaded: Set<String>? = nil) -> LocalModelSelection {
        var sel = LocalModelSelection(modelIDs: ids, downloaded: downloaded ?? [small])
        let boot = attempt(in: sel.boot(selectedID: small))!
        _ = sel.loadSucceeded(boot)
        return sel
    }

    @Test func bootLoadsSelected() {
        var sel = LocalModelSelection(modelIDs: ids, downloaded: [small])
        let effects = sel.boot(selectedID: parakeet)
        let a = attempt(in: effects)!
        #expect(a.modelID == parakeet)
        #expect(effects == [.load(a)])
        #expect(sel.pending == parakeet)
        #expect(sel.active == nil)
    }

    @Test func bootUnknownFallsBackToDefault() {
        var sel = LocalModelSelection(modelIDs: ids, downloaded: [small])
        let effects = sel.boot(selectedID: "x")
        let a = attempt(in: effects)!
        #expect(a.modelID == small)
        #expect(effects == [.load(a), .persistSelection(small)])
        #expect(sel.selected == small)
    }

    @Test func selectStartsLoadAndPersists() {
        var sel = activeSmall()
        let effects = sel.select(turbo)
        let a = attempt(in: effects)!
        #expect(a.modelID == turbo)
        #expect(effects == [.load(a), .persistSelection(turbo)])
        #expect(sel.status(of: turbo) == .downloading(0))
        #expect(sel.selected == turbo)

        var downloadedSel = activeSmall(downloaded: [small, turbo])
        _ = downloadedSel.select(turbo)
        #expect(downloadedSel.status(of: turbo) == .preparing)
    }

    @Test func selectSameIsNoop() {
        var sel = activeSmall()
        #expect(sel.select(small) == [])
        _ = sel.select(turbo)
        let before = sel
        #expect(sel.select(turbo) == [])
        #expect(sel == before)
    }

    @Test func selectActiveWhilePendingCancels() {
        var sel = activeSmall()
        let t = attempt(in: sel.select(turbo))!
        #expect(sel.select(small) == [.cancelLoad(t), .deleteFiles(turbo), .persistSelection(small)])
        #expect(sel.pending == nil)
        #expect(sel.selected == small)
    }

    @Test func selectWhilePendingCancelsPrevious() {
        var sel = activeSmall()
        let t = attempt(in: sel.select(turbo))!
        let effects = sel.select(parakeet)
        let p = attempt(in: effects)!
        #expect(p.modelID == parakeet)
        #expect(p.generation != t.generation)
        #expect(effects == [.cancelLoad(t), .deleteFiles(turbo), .load(p), .persistSelection(parakeet)])
        #expect(sel.status(of: turbo) == .notDownloaded)

        var downloadedSel = activeSmall(downloaded: [small, turbo])
        let t2 = attempt(in: downloadedSel.select(turbo))!
        let effects2 = downloadedSel.select(parakeet)
        let p2 = attempt(in: effects2)!
        #expect(effects2 == [.cancelLoad(t2), .load(p2), .persistSelection(parakeet)])
        #expect(downloadedSel.status(of: turbo) == .downloaded)
    }

    @Test func successSwapsAndUnloadsPrevious() {
        var sel = activeSmall()
        let t = attempt(in: sel.select(turbo))!
        #expect(sel.loadSucceeded(t) == [.unload(small)])
        #expect(sel.active == turbo)
        #expect(sel.pending == nil)
        #expect(sel.status(of: turbo) == .ready)
        #expect(sel.status(of: small) == .downloaded)
    }

    @Test func staleSuccessIsIgnored() {
        var sel = activeSmall()
        let t = attempt(in: sel.select(turbo))!
        let p = attempt(in: sel.select(parakeet))!
        let before = sel
        #expect(sel.loadSucceeded(t) == [])
        #expect(sel == before)
        #expect(sel.pendingAttempt == p)
    }

    @Test func staleSuccessOfSameModelIsIgnored() {
        var sel = activeSmall()
        let a = attempt(in: sel.select(turbo))!
        _ = sel.cancel()
        let b = attempt(in: sel.select(turbo))!
        #expect(a != b)
        #expect(sel.loadSucceeded(a) == [])
        #expect(sel.active == small)
        #expect(sel.pendingAttempt == b)
        #expect(sel.loadSucceeded(b) == [.unload(small)])
        #expect(sel.active == turbo)
    }

    @Test func staleFailureOfSameModelIsIgnored() {
        var sel = activeSmall()
        let a = attempt(in: sel.select(turbo))!
        _ = sel.cancel()
        let b = attempt(in: sel.select(turbo))!
        #expect(sel.loadFailed(a, message: "boom") == [])
        #expect(sel.status(of: turbo) != .failed("boom"))
        #expect(sel.pendingAttempt == b)
        #expect(sel.active == small)
    }

    @Test func staleProgressIsIgnored() {
        var sel = activeSmall()
        let a = attempt(in: sel.select(turbo))!
        _ = sel.cancel()
        let b = attempt(in: sel.select(turbo))!
        sel.progress(b, .downloading(0.3))
        sel.progress(a, .downloading(0.9))
        #expect(sel.status(of: turbo) == .downloading(0.3))
    }

    @Test func failureRevertsToActive() {
        var sel = activeSmall()
        let t = attempt(in: sel.select(turbo))!
        #expect(sel.loadFailed(t, message: "boom") == [.deleteFiles(turbo), .persistSelection(small)])
        #expect(sel.status(of: turbo) == .failed("boom"))
        #expect(sel.selected == small)
        #expect(sel.pending == nil)
    }

    @Test(arguments: [true, false])
    func bootFailureRevertsToDefaultAndLoadsIt(defaultDownloaded: Bool) {
        var sel = LocalModelSelection(modelIDs: ids, downloaded: defaultDownloaded ? [small, turbo] : [turbo])
        let t = attempt(in: sel.boot(selectedID: turbo))!
        let effects = sel.loadFailed(t, message: "boom")
        let d = attempt(in: effects)!
        #expect(d.modelID == small)
        #expect(effects == [.persistSelection(small), .load(d)])
        #expect(sel.pending == small)
        #expect(sel.status(of: small) == (defaultDownloaded ? .preparing : .downloading(0)))
        #expect(sel.status(of: turbo) == .failed("boom"))
    }

    @Test func bootFailureOfDefaultStops() {
        var sel = LocalModelSelection(modelIDs: ids, downloaded: [small])
        let d = attempt(in: sel.boot(selectedID: small))!
        #expect(sel.loadFailed(d, message: "boom") == [])
        #expect(sel.pending == nil)
        #expect(sel.active == nil)
        #expect(sel.status(of: small) == .failed("boom"))
    }

    // QA F15/K8: Core ML crashes the app (it does not throw) on damaged
    // weights. A model whose load was under way when the app died is never
    // loaded again on its own at boot, or the app would crash on every launch.
    @Test func bootSkipsCrashedSelectedAndLoadsDefault() {
        var sel = LocalModelSelection(modelIDs: ids, downloaded: [small, turbo])
        sel.recordCrash(turbo, message: "caiu")
        let effects = sel.boot(selectedID: turbo)
        let d = attempt(in: effects)!
        #expect(d.modelID == small)
        #expect(effects == [.load(d), .persistSelection(small)])
        #expect(sel.status(of: turbo) == .failed("caiu"))
        #expect(sel.hasFiles(turbo))
    }

    @Test func bootOfCrashedDefaultLoadsNothing() {
        var sel = LocalModelSelection(modelIDs: ids, downloaded: [small])
        sel.recordCrash(small, message: "caiu")
        #expect(sel.boot(selectedID: small) == [])
        #expect(sel.pending == nil)
        #expect(sel.active == nil)
        #expect(sel.status(of: small) == .failed("caiu"))

        var both = LocalModelSelection(modelIDs: ids, downloaded: [small, turbo])
        both.recordCrash(small, message: "caiu")
        both.recordCrash(turbo, message: "caiu")
        #expect(both.boot(selectedID: turbo) == [.persistSelection(small)])
        #expect(both.pending == nil)
    }

    @Test func crashedModelLoadsWhenPickedAgain() {
        var sel = LocalModelSelection(modelIDs: ids, downloaded: [small, turbo])
        sel.recordCrash(turbo, message: "caiu")
        _ = sel.loadSucceeded(attempt(in: sel.boot(selectedID: turbo))!)
        let t = attempt(in: sel.select(turbo))!
        #expect(sel.status(of: turbo) == .preparing)
        #expect(sel.loadSucceeded(t) == [.unload(small)])
        #expect(sel.status(of: turbo) == .ready)
    }

    // Review 7 qa r1: the automatic fallback after a failed or cancelled boot
    // attempt must not load the default either when it is the one that crashed.
    @Test func bootFallbackAfterFailureSkipsCrashedDefault() {
        var sel = LocalModelSelection(modelIDs: ids, downloaded: [small, turbo])
        sel.recordCrash(small, message: "caiu")
        let t = attempt(in: sel.boot(selectedID: turbo))!
        #expect(t.modelID == turbo)
        #expect(sel.loadFailed(t, message: "offline") == [.persistSelection(small)])
        #expect(sel.pending == nil)
        #expect(sel.status(of: small) == .failed("caiu"))
    }

    @Test func bootFallbackAfterCancelSkipsCrashedDefault() {
        var sel = LocalModelSelection(modelIDs: ids, downloaded: [small, turbo])
        sel.recordCrash(small, message: "caiu")
        let t = attempt(in: sel.boot(selectedID: turbo))!
        #expect(sel.cancel() == [.cancelLoad(t), .persistSelection(small)])
        #expect(sel.pending == nil)
        #expect(sel.status(of: small) == .failed("caiu"))
    }

    @Test func pickingCrashedDefaultAuthorizesItsFallbackAgain() {
        var sel = LocalModelSelection(modelIDs: ids, downloaded: [small, turbo])
        sel.recordCrash(small, message: "caiu")
        let t = attempt(in: sel.boot(selectedID: turbo))!
        _ = sel.loadFailed(t, message: "offline")

        let s = attempt(in: sel.select(small))!
        #expect(s.modelID == small)
        #expect(sel.status(of: small) == .preparing)
        // Picked explicitly and failing by an error (not a crash): it may serve
        // as the fallback again.
        _ = sel.loadFailed(s, message: "boom")
        let t2 = attempt(in: sel.select(turbo))!
        let effects = sel.loadFailed(t2, message: "offline")
        #expect(attempt(in: effects)?.modelID == small)
    }

    @Test func recordCrashIgnoresUnknownID() {
        var sel = LocalModelSelection(modelIDs: ids, downloaded: [small])
        sel.recordCrash("nope", message: "caiu")
        #expect(sel.status(of: "nope") == .notDownloaded)
        #expect(attempt(in: sel.boot(selectedID: small))?.modelID == small)
    }

    @Test func failureOfIncompleteDownloadDeletesPartials() {
        var sel = LocalModelSelection(modelIDs: ids, downloaded: [])
        let d = attempt(in: sel.boot(selectedID: small))!
        #expect(sel.loadFailed(d, message: "boom") == [.deleteFiles(small)])
        #expect(!sel.hasFiles(small))
    }

    // Regression (review 6 r1): offline at boot, both cached models fail on the
    // repository request. A failed request is no proof the files are bad, so
    // neither cache is deleted.
    @Test func offlineBootKeepsBothCachedModels() {
        var sel = LocalModelSelection(modelIDs: ids, downloaded: [small, turbo])
        let t = attempt(in: sel.boot(selectedID: turbo))!
        let effects = sel.loadFailed(t, message: "offline")
        let d = attempt(in: effects)!
        #expect(effects == [.persistSelection(small), .load(d)])
        #expect(sel.loadFailed(d, message: "offline") == [])
        #expect(sel.hasFiles(small))
        #expect(sel.hasFiles(turbo))
        #expect(sel.status(of: small) == .failed("offline"))

        // A retry loads the files on disk again instead of downloading them.
        let retry = attempt(in: sel.select(small))!
        #expect(sel.status(of: small) == .preparing)
        #expect(sel.loadSucceeded(retry) == [])
        #expect(sel.active == small)
    }

    @Test func failedModelWithFilesCanBeDeleted() {
        var sel = activeSmall(downloaded: [small, turbo])
        let t = attempt(in: sel.select(turbo))!
        #expect(sel.loadFailed(t, message: "boom") == [.persistSelection(small)])
        #expect(sel.hasFiles(turbo))
        #expect(sel.delete(turbo) == [.deleteFiles(turbo)])
        #expect(sel.status(of: turbo) == .notDownloaded)
        #expect(!sel.hasFiles(turbo))
    }

    @Test func cancelRevertsToActiveAndDeletesPartial() {
        var sel = activeSmall()
        let t = attempt(in: sel.select(turbo))!
        #expect(sel.cancel() == [.cancelLoad(t), .deleteFiles(turbo), .persistSelection(small)])
        #expect(sel.status(of: turbo) == .notDownloaded)
        #expect(sel.selected == small)
        #expect(sel.pending == nil)
    }

    @Test(arguments: [true, false])
    func cancelAtBootRevertsToDefault(defaultDownloaded: Bool) {
        // Turbo not downloaded: the partial is deleted.
        var sel = LocalModelSelection(modelIDs: ids, downloaded: defaultDownloaded ? [small] : [])
        let t = attempt(in: sel.boot(selectedID: turbo))!
        let effects = sel.cancel()
        let d = attempt(in: effects)!
        #expect(d.modelID == small)
        #expect(effects == [.cancelLoad(t), .deleteFiles(turbo), .persistSelection(small), .load(d)])
        #expect(sel.pending == small)
        #expect(sel.status(of: small) == (defaultDownloaded ? .preparing : .downloading(0)))

        // Turbo already downloaded: its files stay.
        var kept = LocalModelSelection(modelIDs: ids, downloaded: defaultDownloaded ? [small, turbo] : [turbo])
        let t2 = attempt(in: kept.boot(selectedID: turbo))!
        let effects2 = kept.cancel()
        let d2 = attempt(in: effects2)!
        #expect(effects2 == [.cancelLoad(t2), .persistSelection(small), .load(d2)])
        #expect(kept.status(of: turbo) == .downloaded)
    }

    @Test func cancelAtBootOfDefaultStops() {
        var sel = LocalModelSelection(modelIDs: ids, downloaded: [small])
        let d = attempt(in: sel.boot(selectedID: small))!
        #expect(sel.cancel() == [.cancelLoad(d)])
        #expect(sel.pending == nil)
        #expect(sel.status(of: small) == .downloaded)

        var deleted = LocalModelSelection(modelIDs: ids, downloaded: [])
        let d2 = attempt(in: deleted.boot(selectedID: small))!
        #expect(deleted.cancel() == [.cancelLoad(d2), .deleteFiles(small)])
        #expect(deleted.pending == nil)
    }

    @Test func deleteRefusesActiveAndPending() {
        var sel = activeSmall(downloaded: [small, turbo])
        _ = sel.select(turbo)
        let before = sel
        #expect(sel.delete(small) == [])
        #expect(sel.delete(turbo) == [])
        #expect(sel == before)
    }

    @Test func deleteDownloaded() {
        var sel = activeSmall(downloaded: [small, parakeet])
        #expect(sel.status(of: parakeet) == .downloaded)
        #expect(sel.delete(parakeet) == [.deleteFiles(parakeet)])
        #expect(sel.status(of: parakeet) == .notDownloaded)
    }

    @Test func reselectClearsFailure() {
        var sel = activeSmall()
        let t = attempt(in: sel.select(turbo))!
        _ = sel.loadFailed(t, message: "boom")
        #expect(sel.status(of: turbo) == .failed("boom"))
        _ = sel.select(turbo)
        #expect(sel.status(of: turbo) == .downloading(0))
    }
}
