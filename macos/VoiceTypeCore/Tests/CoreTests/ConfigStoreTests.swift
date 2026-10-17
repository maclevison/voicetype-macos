import Foundation
import Testing
@testable import Core

@Suite("ConfigStore", .serialized)
struct ConfigStoreTests {

    // Make a fresh temp directory + return its config.json URL.
    private func makeTempStore() throws -> (store: ConfigStore, dir: URL, configURL: URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("voicetype-cfgstore-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let configURL = dir.appendingPathComponent("config.json")
        let store = ConfigStore(fileURL: configURL)
        return (store, dir, configURL)
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("returns defaults when no file exists")
    func loadsDefaultsFromEmpty() async throws {
        let (store, dir, _) = try makeTempStore()
        defer { cleanup(dir) }

        let cfg = try await store.load()
        #expect(cfg == AppConfig())
    }

    @Test("returns persisted config when file is valid")
    func loadsPersisted() async throws {
        let (store, dir, configURL) = try makeTempStore()
        defer { cleanup(dir) }

        var seed = AppConfig()
        seed.groq.apiKey = "gsk_persisted"
        let data = try JSONEncoder().encode(seed)
        try data.write(to: configURL)

        let cfg = try await store.load()
        #expect(cfg.groq.apiKey == "gsk_persisted")
    }

    @Test("falls back to defaults when file is corrupted and removes the bad file")
    func recoversFromCorruption() async throws {
        let (store, dir, configURL) = try makeTempStore()
        defer { cleanup(dir) }

        try "not json at all".data(using: .utf8)!.write(to: configURL)

        let cfg = try await store.load()
        #expect(cfg == AppConfig())
        #expect(!FileManager.default.fileExists(atPath: configURL.path))
    }

    @Test("save persists a valid partial config")
    func savesValid() async throws {
        let (store, dir, _) = try makeTempStore()
        defer { cleanup(dir) }

        var next = AppConfig()
        next.groq.apiKey = "gsk_valid"
        try await store.save(next)

        let reloaded = try await store.load()
        #expect(reloaded.groq.apiKey == "gsk_valid")
    }

    @Test("save + load round-trips the refine fields")
    func roundTripsRefineFields() async throws {
        let (store, dir, _) = try makeTempStore()
        defer { cleanup(dir) }

        var next = AppConfig()
        next.refineBypassDisabledApps = ["com.apple.Terminal"]
        next.recording.refineStyle = "formal"
        next.appStyleOverrides = ["com.apple.mail": "concise"]
        next.categoryStyles = ["chat": "concise"]
        next.cursorContextEnabled = true
        next.learnFromEditsEnabled = true
        try await store.save(next)

        let reloaded = try await store.load()
        #expect(reloaded == next)
    }

    @Test("save rejects invalid groqApiKey without mutating the file")
    func rejectsInvalidKey() async throws {
        let (store, dir, _) = try makeTempStore()
        defer { cleanup(dir) }

        var seed = AppConfig()
        seed.groq.apiKey = "gsk_seed"
        try await store.save(seed)

        var bad = AppConfig()
        bad.groq.apiKey = "totally_invalid"
        await #expect(throws: AppConfig.ValidationError.self) {
            try await store.save(bad)
        }

        let cfg = try await store.load()
        #expect(cfg.groq.apiKey == "gsk_seed")
    }

    @Test("subscribers are notified on successful save")
    func notifiesOnSave() async throws {
        let (store, dir, _) = try makeTempStore()
        defer { cleanup(dir) }

        let collector = AsyncCollector<AppConfig>.empty()
        let cancellable = await store.subscribe { cfg in
            Task { await collector.append(cfg) }
        }
        defer { cancellable.cancel() }

        var next = AppConfig()
        next.showHud = false
        try await store.save(next)

        let received = await collector.take(count: 1)
        #expect(received.count == 1)
        #expect(received[0].showHud == false)
    }

    @Test("subscribers are not notified when save fails validation")
    func skipsNotifyOnFailure() async throws {
        let (store, dir, _) = try makeTempStore()
        defer { cleanup(dir) }

        let collector = AsyncCollector<AppConfig>.empty()
        let cancellable = await store.subscribe { cfg in
            Task { await collector.append(cfg) }
        }
        defer { cancellable.cancel() }

        var bad = AppConfig()
        bad.groq.apiKey = "nope"
        _ = try? await store.save(bad)

        // Give callbacks a beat to dispatch.
        try await Task.sleep(nanoseconds: 50_000_000)
        let received = await collector.takeAvailable()
        #expect(received.isEmpty)
    }

    @Test("cancel() detaches a subscriber")
    func unsubscribe() async throws {
        let (store, dir, _) = try makeTempStore()
        defer { cleanup(dir) }

        let collector = AsyncCollector<AppConfig>.empty()
        let cancellable = await store.subscribe { cfg in
            Task { await collector.append(cfg) }
        }
        cancellable.cancel()

        var next = AppConfig()
        next.showHud = false
        try await store.save(next)

        try await Task.sleep(nanoseconds: 50_000_000)
        let received = await collector.takeAvailable()
        #expect(received.isEmpty)
    }

    @Test("subscriber list is snapshotted before notify (FU-004 mitigation)")
    func reentrantSafe() async throws {
        let (store, dir, _) = try makeTempStore()
        defer { cleanup(dir) }

        // First subscriber, on its first notify, registers a second subscriber.
        // The second subscriber must NOT fire for the same save that registered it.
        let lateCollector = AsyncCollector<AppConfig>.empty()
        let firstFired = AsyncCollector<Int>.empty()

        let first = await store.subscribe { _ in
            Task {
                await firstFired.append(1)
                // Register a late subscriber inside the callback.
                _ = await store.subscribe { cfg in
                    Task { await lateCollector.append(cfg) }
                }
            }
        }
        defer { first.cancel() }

        var next = AppConfig()
        next.showHud = false
        try await store.save(next)

        try await Task.sleep(nanoseconds: 100_000_000)
        let lateReceived = await lateCollector.takeAvailable()
        let firstReceived = await firstFired.takeAvailable()
        #expect(firstReceived == [1])
        #expect(lateReceived.isEmpty)
    }

    @Test("atomic write does not leave a .tmp sibling after a successful save")
    func noTmpLeak() async throws {
        let (store, dir, configURL) = try makeTempStore()
        defer { cleanup(dir) }

        var next = AppConfig()
        next.groq.apiKey = "gsk_atomic"
        try await store.save(next)

        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(siblings.contains(configURL.lastPathComponent))
        #expect(!siblings.contains { $0.hasSuffix(".tmp") })
    }

    @Test("simulated crash mid-write leaves the prior file intact (rename atomicity)")
    func atomicityUnderFailure() async throws {
        let (store, dir, configURL) = try makeTempStore()
        defer { cleanup(dir) }

        // Seed a valid file.
        var seed = AppConfig()
        seed.groq.apiKey = "gsk_seed"
        try await store.save(seed)

        // Drop a .tmp file as if a previous save had been interrupted before rename.
        let tmpURL = configURL.appendingPathExtension("tmp")
        try Data("partial garbage".utf8).write(to: tmpURL)

        // Load must still return the seed value; the .tmp is irrelevant.
        let cfg = try await store.load()
        #expect(cfg.groq.apiKey == "gsk_seed")

        // A subsequent successful save replaces the file atomically and cleans up the .tmp.
        var next = AppConfig()
        next.groq.apiKey = "gsk_recovered"
        try await store.save(next)

        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!siblings.contains { $0.hasSuffix(".tmp") })

        let reloaded = try await store.load()
        #expect(reloaded.groq.apiKey == "gsk_recovered")
    }

    @Test func configStore_reads_v1_file_and_persists_as_v2() async throws {
        let url = URL(fileURLWithPath: "/tmp/voicetype-migration-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let v1Json = """
        {
            "schemaVersion": 1,
            "groqApiKey": "gsk_legacy",
            "globalShortcut": "CommandOrControl+Shift+Space",
            "translateShortcut": "CommandOrControl+Shift+E",
            "translateEnabled": false,
            "translateTargetLanguage": "en-US",
            "language": "pt-BR",
            "refineStyle": "natural",
            "inputDeviceID": "",
            "inputDeviceLabel": "",
            "historyEnabled": true,
            "historyRetentionCount": 100,
            "historyRetentionDays": 7,
            "startAtLogin": false,
            "showHud": true,
            "errorNotifications": true,
            "handsFreeEnabled": true
        }
        """
        try v1Json.write(to: url, atomically: true, encoding: .utf8)

        let store = ConfigStore(fileURL: url)
        let loaded = try await store.load()
        #expect(loaded.schemaVersion == 2)
        #expect(loaded.groq.apiKey == "gsk_legacy")

        // Save triggers re-persist in v2 shape.
        try await store.save(loaded)
        let raw = try String(contentsOf: url, encoding: .utf8)
        #expect(raw.contains("\"groq\""), "saved file must contain nested groq object")
        #expect(raw.contains("\"schemaVersion\" : 2"))
        #expect(!raw.contains("\"groqApiKey\""), "saved file must not contain v1 flat keys")
    }

    @Test("shortcutCancelWindowMs survives save + reload")
    func shortcutCancelWindowRoundTrip() async throws {
        let (store, dir, configURL) = try makeTempStore()
        defer { cleanup(dir) }

        var cfg = AppConfig()
        cfg.shortcutCancelWindowMs = 750
        try await store.save(cfg)

        let reloaded = try await ConfigStore(fileURL: configURL).load()
        #expect(reloaded.shortcutCancelWindowMs == 750)
    }

    @Test("meeting fields survive save + reload")
    func meetingFieldsRoundTrip() async throws {
        let (store, dir, configURL) = try makeTempStore()
        defer { cleanup(dir) }

        var cfg = AppConfig()
        cfg.meetingNotesFolder = "/tmp/vault/Meetings"
        cfg.claudeCLIPath = "/opt/custom/claude"
        cfg.meetingOrgs = [MeetingOrg(name: "Acme", aliases: ["AC"], clients: [MeetingClient(name: "Foo", aliases: ["F"])])]
        cfg.meetingDetectionMode = "auto"
        cfg.meetingAudioRetentionDays = 0
        try await store.save(cfg)

        let reloaded = try await ConfigStore(fileURL: configURL).load()
        #expect(reloaded.meetingNotesFolder == "/tmp/vault/Meetings")
        #expect(reloaded.claudeCLIPath == "/opt/custom/claude")
        #expect(reloaded.meetingOrgs == cfg.meetingOrgs)
        #expect(reloaded.meetingDetectionMode == "auto")
        #expect(reloaded.meetingAudioRetentionDays == 0)
    }

    @Test("voiceNoteShortcut survives save + reload")
    func voiceNoteShortcutRoundTrip() async throws {
        let (store, dir, configURL) = try makeTempStore()
        defer { cleanup(dir) }

        var cfg = AppConfig()
        cfg.voiceNoteShortcut = "Control+Alt+I"
        try await store.save(cfg)

        #expect(try await ConfigStore(fileURL: configURL).load().voiceNoteShortcut == "Control+Alt+I")
    }

    @Test("meeting vault kind + OK path survive save + reload")
    func vaultKindRoundTrip() async throws {
        let (store, dir, configURL) = try makeTempStore()
        defer { cleanup(dir) }

        var cfg = AppConfig()
        cfg.meetingVaultKind = .openKnowledge
        cfg.openKnowledgeVaultPath = "/tmp/MB"
        try await store.save(cfg)

        let reloaded = try await ConfigStore(fileURL: configURL).load()
        #expect(reloaded.meetingVaultKind == .openKnowledge)
        #expect(reloaded.openKnowledgeVaultPath == "/tmp/MB")
    }

    @Test("first run seeds the refine shortcut by hardware")
    func firstRunSeedsShortcut() async throws {
        let (fnStore, fnDir, _) = try makeTempStore()
        defer { cleanup(fnDir) }
        #expect(try await fnStore.seedFirstRunShortcut(hasAppleFnKey: true))
        #expect(try await fnStore.load().shortcuts.refine == "Fn")

        let (extStore, extDir, extURL) = try makeTempStore()
        defer { cleanup(extDir) }
        try await extStore.seedFirstRunShortcut(hasAppleFnKey: false)
        #expect(try await ConfigStore(fileURL: extURL).load().shortcuts.refine == "Control+Alt")
    }

    @Test("existing config is never overwritten by the hardware default")
    func seedNeverOverwrites() async throws {
        let (store, dir, configURL) = try makeTempStore()
        defer { cleanup(dir) }
        var cfg = AppConfig()
        cfg.shortcuts.refine = "CommandOrControl+Shift+K"
        try await store.save(cfg)

        // e.g. later boot with an Apple keyboard hot-plugged
        #expect(try await ConfigStore(fileURL: configURL).seedFirstRunShortcut(hasAppleFnKey: true) == false)
        #expect(try await ConfigStore(fileURL: configURL).load().shortcuts.refine == "CommandOrControl+Shift+K")
    }

    @Test("hands-free fields survive save + reload")
    func handsFreeRoundTrip() async throws {
        let (store, dir, configURL) = try makeTempStore()
        defer { cleanup(dir) }

        var cfg = AppConfig()
        cfg.handsFreeEnabled = false
        cfg.handsFreeUpgradeKey = "Tab"
        try await store.save(cfg)

        let reloaded = try await ConfigStore(fileURL: configURL).load()
        #expect(reloaded.handsFreeEnabled == false)
        #expect(reloaded.handsFreeUpgradeKey == "Tab")
    }

    @Test("resetForTests() clears in-memory caches and subscribers")
    func resetForTestsClears() async throws {
        let (store, dir, _) = try makeTempStore()
        defer { cleanup(dir) }

        let collector = AsyncCollector<AppConfig>.empty()
        _ = await store.subscribe { cfg in
            Task { await collector.append(cfg) }
        }

        await store.resetForTests()

        var next = AppConfig()
        next.showHud = false
        try await store.save(next)

        try await Task.sleep(nanoseconds: 50_000_000)
        let received = await collector.takeAvailable()
        #expect(received.isEmpty)
    }
}

// MARK: - AsyncCollector convenience

extension AsyncCollector {
    static func empty() -> AsyncCollector<Element> {
        AsyncCollector<Element>(stream: AsyncStream { _ in })
    }
}
