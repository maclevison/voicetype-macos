import Foundation
import Testing
@testable import Core

@Suite("AppConfig")
struct AppConfigCodableTests {

    // MARK: - v2 defaults

    @Test func defaults_v2_shape() {
        let cfg = AppConfig()
        #expect(cfg.schemaVersion == 2)
        #expect(cfg.groq.apiKey == "")
        #expect(cfg.shortcuts.refine == "CommandOrControl+Shift+Space")
        #expect(cfg.shortcuts.translate == "CommandOrControl+Shift+E")
        #expect(cfg.recording.language == "pt-BR")
        #expect(cfg.recording.refineStyle == "natural")
        #expect(cfg.recording.inputDeviceID == "")
        #expect(cfg.recording.inputDeviceLabel == "")
        #expect(cfg.translate.enabled == false)
        #expect(cfg.translate.target == "en-US")
        #expect(cfg.history.enabled == true)
        #expect(cfg.history.retentionCount == 100)
        #expect(cfg.history.retentionDays == 7)
        #expect(cfg.startAtLogin == false)
        #expect(cfg.showHud == true)
        #expect(cfg.errorNotifications == true)
        #expect(cfg.handsFreeEnabled == true)
        #expect(cfg.waveformPreset == "aurora")
        #expect(cfg.indicatorStyle == "auto")
        #expect(cfg.soundFeedbackEnabled == true)
        #expect(cfg.autoEnterEnabled == false)
    }

    // MARK: - v1 → v2 migration

    @Test func decode_v1_payload_migrates_to_v2() throws {
        let v1Json = """
        {
            "schemaVersion": 1,
            "groqApiKey": "gsk_abc",
            "globalShortcut": "CommandOrControl+Shift+Space",
            "translateShortcut": "CommandOrControl+Shift+E",
            "translateEnabled": true,
            "translateTargetLanguage": "pt-BR",
            "language": "en-US",
            "refineStyle": "formal",
            "inputDeviceID": "dev123",
            "inputDeviceLabel": "Studio Mic",
            "historyEnabled": false,
            "historyRetentionCount": 42,
            "historyRetentionDays": 14,
            "startAtLogin": true,
            "showHud": false,
            "errorNotifications": false,
            "handsFreeEnabled": false
        }
        """.data(using: .utf8)!

        let cfg = try JSONDecoder().decode(AppConfig.self, from: v1Json)

        #expect(cfg.schemaVersion == 2, "must promote to v2")
        #expect(cfg.groq.apiKey == "gsk_abc")
        #expect(cfg.shortcuts.refine == "CommandOrControl+Shift+Space")
        #expect(cfg.shortcuts.translate == "CommandOrControl+Shift+E")
        #expect(cfg.translate.enabled == true)
        #expect(cfg.translate.target == "pt-BR")
        #expect(cfg.recording.language == "en-US")
        #expect(cfg.recording.refineStyle == "formal")
        #expect(cfg.recording.inputDeviceID == "dev123")
        #expect(cfg.recording.inputDeviceLabel == "Studio Mic")
        #expect(cfg.history.enabled == false)
        #expect(cfg.history.retentionCount == 42)
        #expect(cfg.history.retentionDays == 14)
        #expect(cfg.startAtLogin == true)
        #expect(cfg.showHud == false)
        #expect(cfg.errorNotifications == false)
        #expect(cfg.handsFreeEnabled == false)
        #expect(cfg.indicatorStyle == "auto")
        #expect(cfg.soundFeedbackEnabled == true)
    }

    @Test func decode_v1_partial_falls_back_to_defaults() throws {
        let v1Json = #"""
        {"schemaVersion": 1, "groqApiKey": "gsk_xyz"}
        """#.data(using: .utf8)!

        let cfg = try JSONDecoder().decode(AppConfig.self, from: v1Json)
        let defaults = AppConfig()

        #expect(cfg.schemaVersion == 2)
        #expect(cfg.groq.apiKey == "gsk_xyz")
        #expect(cfg.shortcuts == defaults.shortcuts)
        #expect(cfg.recording == defaults.recording)
        #expect(cfg.history == defaults.history)
    }

    @Test func decode_v2_roundtrip_stable() throws {
        let original = AppConfig(
            groq: GroqConfig(apiKey: "gsk_test"),
            shortcuts: ShortcutConfig(refine: "Alt+R", translate: "Alt+T"),
            history: HistoryConfig(enabled: true, retentionCount: 50, retentionDays: 7)
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: encoded)
        #expect(decoded == original)
    }

    // MARK: - waveformPreset

    @Test func waveformPreset_roundtrip() throws {
        let original = AppConfig(waveformPreset: "ocean")
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: encoded)
        #expect(decoded.waveformPreset == "ocean")
        #expect(decoded == original)
    }

    @Test func waveformPreset_missing_falls_back_to_aurora() throws {
        let json = """
        {
            "schemaVersion": 2,
            "groq": {"apiKey": ""},
            "shortcuts": {"refine": "CommandOrControl+Shift+Space", "translate": "CommandOrControl+Shift+E"},
            "recording": {"language": "pt-BR", "refineStyle": "natural", "inputDeviceID": "", "inputDeviceLabel": ""},
            "translate": {"enabled": false, "target": "en-US"},
            "history": {"enabled": true, "retentionCount": 100, "retentionDays": 7},
            "startAtLogin": false,
            "showHud": true,
            "errorNotifications": true,
            "handsFreeEnabled": true
        }
        """.data(using: .utf8)!

        let cfg = try JSONDecoder().decode(AppConfig.self, from: json)
        #expect(cfg.waveformPreset == "aurora")
    }

    // MARK: - indicatorStyle

    @Test func indicatorStyle_roundtrip() throws {
        let original = AppConfig(indicatorStyle: "notch")
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: encoded)
        #expect(decoded.indicatorStyle == "notch")
        #expect(decoded == original)
    }

    @Test func indicatorStyle_missing_falls_back_to_auto() throws {
        let json = """
        {
            "schemaVersion": 2,
            "groq": {"apiKey": ""},
            "shortcuts": {"refine": "CommandOrControl+Shift+Space", "translate": "CommandOrControl+Shift+E"},
            "recording": {"language": "pt-BR", "refineStyle": "natural", "inputDeviceID": "", "inputDeviceLabel": ""},
            "translate": {"enabled": false, "target": "en-US"},
            "history": {"enabled": true, "retentionCount": 100, "retentionDays": 7},
            "startAtLogin": false,
            "showHud": true,
            "errorNotifications": true,
            "handsFreeEnabled": true,
            "waveformPreset": "aurora"
        }
        """.data(using: .utf8)!

        let cfg = try JSONDecoder().decode(AppConfig.self, from: json)
        #expect(cfg.indicatorStyle == "auto")
    }

    // MARK: - soundFeedbackEnabled

    @Test func soundFeedbackEnabled_roundtrip() throws {
        let original = AppConfig(soundFeedbackEnabled: false)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: encoded)
        #expect(decoded.soundFeedbackEnabled == false)
        #expect(decoded == original)
    }

    // MARK: - autoEnterEnabled

    @Test func autoEnterEnabled_default_false() {
        let cfg = AppConfig()
        #expect(cfg.autoEnterEnabled == false)
    }

    @Test func autoEnterEnabled_roundtrip() throws {
        let original = AppConfig(autoEnterEnabled: true)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: encoded)
        #expect(decoded.autoEnterEnabled == true)
        #expect(decoded == original)
    }

    @Test func autoEnterEnabled_missing_falls_back_to_false() throws {
        let json = """
        {
            "schemaVersion": 2,
            "groq": {"apiKey": ""},
            "shortcuts": {"refine": "CommandOrControl+Shift+Space", "translate": "CommandOrControl+Shift+E"},
            "recording": {"language": "pt-BR", "refineStyle": "natural", "inputDeviceID": "", "inputDeviceLabel": ""},
            "translate": {"enabled": false, "target": "en-US"},
            "history": {"enabled": true, "retentionCount": 100, "retentionDays": 7},
            "startAtLogin": false,
            "showHud": true,
            "errorNotifications": true,
            "handsFreeEnabled": true,
            "waveformPreset": "aurora",
            "indicatorStyle": "auto",
            "soundFeedbackEnabled": true
        }
        """.data(using: .utf8)!

        let cfg = try JSONDecoder().decode(AppConfig.self, from: json)
        #expect(cfg.autoEnterEnabled == false)
    }

    @Test func autoEnterEnabled_missing_in_v1_falls_back_to_false() throws {
        let v1Json = """
        {"schemaVersion": 1, "groqApiKey": "gsk_xyz"}
        """.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(AppConfig.self, from: v1Json)
        #expect(cfg.autoEnterEnabled == false)
    }

    // MARK: - continuityFallbackEnabled

    @Test func continuityFallbackEnabled_default_true() {
        let cfg = AppConfig()
        #expect(cfg.continuityFallbackEnabled == true)
    }

    @Test func continuityFallbackEnabled_roundtrip_false() throws {
        let original = AppConfig(continuityFallbackEnabled: false)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: encoded)
        #expect(decoded.continuityFallbackEnabled == false)
        #expect(decoded == original)
    }

    @Test func continuityFallbackEnabled_missing_in_v2_falls_back_to_true() throws {
        let json = """
        {
            "schemaVersion": 2,
            "groq": {"apiKey": ""},
            "shortcuts": {"refine": "CommandOrControl+Shift+Space", "translate": "CommandOrControl+Shift+E"},
            "recording": {"language": "pt-BR", "refineStyle": "natural", "inputDeviceID": "", "inputDeviceLabel": ""},
            "translate": {"enabled": false, "target": "en-US"},
            "history": {"enabled": true, "retentionCount": 100, "retentionDays": 7},
            "startAtLogin": false,
            "showHud": true,
            "errorNotifications": true,
            "handsFreeEnabled": true,
            "waveformPreset": "aurora",
            "indicatorStyle": "auto",
            "soundFeedbackEnabled": true,
            "autoEnterEnabled": false
        }
        """.data(using: .utf8)!

        let cfg = try JSONDecoder().decode(AppConfig.self, from: json)
        #expect(cfg.continuityFallbackEnabled == true)
    }

    @Test func continuityFallbackEnabled_missing_in_v1_falls_back_to_true() throws {
        let v1Json = """
        {"schemaVersion": 1, "groqApiKey": "gsk_xyz"}
        """.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(AppConfig.self, from: v1Json)
        #expect(cfg.continuityFallbackEnabled == true)
    }

    // MARK: - vocabularyKeywords

    @Test func vocabularyKeywords_default_empty() {
        let cfg = AppConfig()
        #expect(cfg.vocabularyKeywords == "")
    }

    @Test func vocabularyKeywords_roundtrip() throws {
        let original = AppConfig(vocabularyKeywords: "Macsilva, Codex\nFluidAudio")
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: encoded)
        #expect(decoded.vocabularyKeywords == "Macsilva, Codex\nFluidAudio")
        #expect(decoded == original)
    }

    @Test func vocabularyKeywords_missing_in_v2_falls_back_to_empty() throws {
        let json = """
        {
            "schemaVersion": 2,
            "groq": {"apiKey": ""},
            "shortcuts": {"refine": "CommandOrControl+Shift+Space", "translate": "CommandOrControl+Shift+E"},
            "recording": {"language": "pt-BR", "refineStyle": "natural", "inputDeviceID": "", "inputDeviceLabel": ""},
            "translate": {"enabled": false, "target": "en-US"},
            "history": {"enabled": true, "retentionCount": 100, "retentionDays": 7},
            "startAtLogin": false,
            "showHud": true,
            "errorNotifications": true,
            "handsFreeEnabled": true,
            "waveformPreset": "aurora",
            "indicatorStyle": "auto",
            "soundFeedbackEnabled": true,
            "autoEnterEnabled": false
        }
        """.data(using: .utf8)!

        let cfg = try JSONDecoder().decode(AppConfig.self, from: json)
        #expect(cfg.vocabularyKeywords == "")
    }

    @Test func vocabularyKeywords_missing_in_v1_falls_back_to_empty() throws {
        let v1Json = """
        {"schemaVersion": 1, "groqApiKey": "gsk_xyz"}
        """.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(AppConfig.self, from: v1Json)
        #expect(cfg.vocabularyKeywords == "")
    }

    @Test func soundFeedbackEnabled_missing_falls_back_to_true() throws {
        let json = """
        {
            "schemaVersion": 2,
            "groq": {"apiKey": ""},
            "shortcuts": {"refine": "CommandOrControl+Shift+Space", "translate": "CommandOrControl+Shift+E"},
            "recording": {"language": "pt-BR", "refineStyle": "natural", "inputDeviceID": "", "inputDeviceLabel": ""},
            "translate": {"enabled": false, "target": "en-US"},
            "history": {"enabled": true, "retentionCount": 100, "retentionDays": 7},
            "startAtLogin": false,
            "showHud": true,
            "errorNotifications": true,
            "handsFreeEnabled": true,
            "waveformPreset": "aurora",
            "indicatorStyle": "auto"
        }
        """.data(using: .utf8)!

        let cfg = try JSONDecoder().decode(AppConfig.self, from: json)
        #expect(cfg.soundFeedbackEnabled == true)
    }

    // MARK: - Legacy payload without schemaVersion treated as v1

    @Test("legacy payload without schemaVersion treated as v1 and migrated")
    func legacyDecodeNoVersion() throws {
        let legacyJSON = """
        {
          "groqApiKey": "gsk_abc",
          "globalShortcut": "CommandOrControl+Shift+V",
          "startAtLogin": false,
          "showHud": true,
          "errorNotifications": true,
          "historyRetentionDays": 7,
          "handsFreeEnabled": true,
          "translateEnabled": false,
          "translateShortcut": "CommandOrControl+Shift+E"
        }
        """.data(using: .utf8)!

        let cfg = try JSONDecoder().decode(AppConfig.self, from: legacyJSON)
        #expect(cfg.schemaVersion == 2)
        #expect(cfg.groq.apiKey == "gsk_abc")
        #expect(cfg.shortcuts.refine == "CommandOrControl+Shift+V")
        #expect(cfg.recording.language == "pt-BR")
        #expect(cfg.history.enabled == true)
        #expect(cfg.history.retentionCount == 100)
    }

    // MARK: - Validation

    @Test("validate() rejects groq.apiKey without gsk_ prefix")
    func rejectsBadKey() {
        var cfg = AppConfig()
        cfg.groq.apiKey = "not-a-real-key"
        #expect(throws: AppConfig.ValidationError.self) {
            try cfg.validate()
        }
    }

    @Test("validate() accepts empty groq.apiKey or one starting with gsk_")
    func acceptsValidKey() throws {
        var cfg = AppConfig()
        cfg.groq.apiKey = ""
        try cfg.validate()
        cfg.groq.apiKey = "gsk_valid"
        try cfg.validate()
    }

    @Test("validate() rejects shortcuts.translate == shortcuts.refine when translate.enabled is true")
    func rejectsShortcutCollision() {
        var cfg = AppConfig()
        cfg.translate.enabled = true
        cfg.shortcuts.translate = cfg.shortcuts.refine
        #expect(throws: AppConfig.ValidationError.self) {
            try cfg.validate()
        }
    }

    @Test("validate() allows identical shortcuts when translate.enabled is false")
    func allowsCollisionWhenDisabled() throws {
        var cfg = AppConfig()
        cfg.translate.enabled = false
        cfg.shortcuts.translate = cfg.shortcuts.refine
        try cfg.validate()
    }

    @Test("validate() rejects history.retentionDays outside 0...365")
    func rejectsOutOfRangeRetention() {
        var cfg = AppConfig()
        cfg.history.retentionDays = -1
        #expect(throws: AppConfig.ValidationError.self) { try cfg.validate() }
        cfg.history.retentionDays = 366
        #expect(throws: AppConfig.ValidationError.self) { try cfg.validate() }
    }

    // MARK: - transcriptionEngine

    @Test func transcriptionEngine_defaults_and_roundtrips() throws {
        var cfg = AppConfig()
        #expect(cfg.transcriptionEngine == "auto")
        cfg.transcriptionEngine = "local"
        let data = try JSONEncoder().encode(cfg)
        let back = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(back.transcriptionEngine == "local")
    }

    @Test func transcriptionEngine_absentDecodesToAuto() throws {
        let json = try JSONEncoder().encode(AppConfig())
        var obj = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        obj.removeValue(forKey: "transcriptionEngine")
        let stripped = try JSONSerialization.data(withJSONObject: obj)
        let back = try JSONDecoder().decode(AppConfig.self, from: stripped)
        #expect(back.transcriptionEngine == "auto")
    }

    // MARK: - refineEngine & translateEngine

    @Test func refineTranslateEngineDefaultsAndRoundTrip() throws {
        var cfg = AppConfig()
        #expect(cfg.refineEngine == "auto")
        #expect(cfg.translateEngine == "auto")
        cfg.refineEngine = "local"
        cfg.translateEngine = "groq"
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.refineEngine == "local")
        #expect(decoded.translateEngine == "groq")
    }

    @Test func legacyJsonWithoutEngineFieldsUsesDefaults() throws {
        // A v2 payload missing the new keys must decode to "auto" (additive).
        let json = #"{"schemaVersion": 2, "transcriptionEngine": "auto"}"#
        let decoded = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(decoded.refineEngine == "auto")
        #expect(decoded.translateEngine == "auto")
    }

    // MARK: - refineBypassDisabledApps (#53)

    @Test func refineBypassDisabledApps_default_empty() {
        #expect(AppConfig().refineBypassDisabledApps == [])
    }

    @Test func refineBypassDisabledApps_roundtrip() throws {
        let original = AppConfig(refineBypassDisabledApps: ["com.googlecode.iterm2"])
        let decoded = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }

    @Test func refineBypassDisabledApps_missing_falls_back_to_empty() throws {
        let json = #"{"schemaVersion": 2, "autoEnterEnabled": true}"#.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(AppConfig.self, from: json)
        #expect(cfg.refineBypassDisabledApps == [])
        #expect(cfg.autoEnterEnabled == true)
    }

    // MARK: - style by app (#44)

    @Test func styleFields_defaults() {
        let cfg = AppConfig()
        #expect(cfg.appStyleOverrides == [:])
        #expect(cfg.categoryStyles == RefineStyle.defaultCategoryStyles)
    }

    @Test func styleFields_roundtrip() throws {
        let original = AppConfig(appStyleOverrides: ["com.apple.mail": "concise"], categoryStyles: ["chat": "concise"])
        let decoded = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }

    @Test func styleFields_missing_fall_back_to_defaults() throws {
        let json = #"{"schemaVersion": 2}"#.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(AppConfig.self, from: json)
        #expect(cfg.appStyleOverrides == [:])
        #expect(cfg.categoryStyles == RefineStyle.defaultCategoryStyles)
    }

    // MARK: - cursorContextEnabled (#54)

    @Test func cursorContextEnabled_default_false_and_roundtrip() throws {
        #expect(AppConfig().cursorContextEnabled == false)
        let original = AppConfig(cursorContextEnabled: true)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
        let missing = try JSONDecoder().decode(AppConfig.self, from: #"{"schemaVersion": 2}"#.data(using: .utf8)!)
        #expect(missing.cursorContextEnabled == false)
    }

    // MARK: - learnFromEditsEnabled (#50)

    @Test func learnFromEditsEnabled_default_false_and_roundtrip() throws {
        #expect(AppConfig().learnFromEditsEnabled == false)
        let original = AppConfig(learnFromEditsEnabled: true)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
        let missing = try JSONDecoder().decode(AppConfig.self, from: #"{"schemaVersion": 2}"#.data(using: .utf8)!)
        #expect(missing.learnFromEditsEnabled == false)
    }

    // MARK: - shortcutCancelWindowMs

    @Test func shortcutCancelWindowMsDefaultsAndMissingKeyFallback() throws {
        #expect(AppConfig().shortcutCancelWindowMs == 1000)
        let json = #"{"schemaVersion": 2}"#
        let decoded = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(decoded.shortcutCancelWindowMs == 1000)
    }

    @Test func handsFreeUpgradeKeyDefaultsAndMissingKeyFallback() throws {
        #expect(AppConfig().handsFreeUpgradeKey == "Space")
        let json = #"{"schemaVersion": 2}"#
        let decoded = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(decoded.handsFreeUpgradeKey == "Space")
    }

    // MARK: - meeting (#74)

    @Test func meetingFieldsDefaultAndMissingKeyFallback() throws {
        #expect(AppConfig().meetingNotesFolder == "~/Documents/Meetings")
        #expect(AppConfig().claudeCLIPath == nil)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"schemaVersion": 2}"#.utf8))
        #expect(decoded.meetingNotesFolder == "~/Documents/Meetings")
        #expect(decoded.claudeCLIPath == nil)
        #expect(decoded.meetingOrgs == MeetingOrg.defaults)
        #expect(AppConfig().meetingDetectionMode == "ask")
        #expect(decoded.meetingDetectionMode == "ask")
        #expect(AppConfig().meetingAudioRetentionDays == 7)
        #expect(decoded.meetingAudioRetentionDays == 7)
    }

    @Test func voiceNoteShortcutDefaultsAndMissingKeyFallback() throws {
        #expect(AppConfig().voiceNoteShortcut == "Alt+N")
        let decoded = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"schemaVersion": 2}"#.utf8))
        #expect(decoded.voiceNoteShortcut == "Alt+N")
    }

    @Test func vaultKindDefaultsAndTolerantDecode() throws {
        #expect(AppConfig().meetingVaultKind == .obsidian)
        #expect(AppConfig().openKnowledgeVaultPath == "")
        let missing = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"schemaVersion":2}"#.utf8))
        #expect(missing.meetingVaultKind == .obsidian)
        #expect(missing.openKnowledgeVaultPath == "")
        let garbage = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"schemaVersion":2,"meetingVaultKind":"notion"}"#.utf8))
        #expect(garbage.meetingVaultKind == .obsidian)
        let v1 = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"groqApiKey":"k"}"#.utf8))
        #expect(v1.meetingVaultKind == .obsidian)
        #expect(v1.openKnowledgeVaultPath == "")
    }

    @Test func meetingOrgsDefaultCatalogAndTolerantEntries() throws {
        #expect(AppConfig().meetingOrgs == [MeetingOrg(name: "Pessoal")])
        // Hand-edited entries may omit aliases/clients.
        let json = #"{"schemaVersion": 2, "meetingOrgs": [{"name": "Acme", "clients": [{"name": "Foo"}]}]}"#
        let decoded = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(decoded.meetingOrgs == [MeetingOrg(name: "Acme", clients: [MeetingClient(name: "Foo")])])
    }
}

/// Fictional catalog for tests; the shipped default holds no client data.
extension MeetingOrg {
    static let testCatalog: [MeetingOrg] = [
        MeetingOrg(name: "Initech", aliases: ["IT", "Ini"], clients: [
            MeetingClient(name: "Globex", aliases: ["Globex Corp"]),
            MeetingClient(name: "Hooli"),
            MeetingClient(name: "Umbrella", aliases: ["Umbrella Corporation"]),
            MeetingClient(name: "Soylent"),
        ]),
        MeetingOrg(name: "Pessoal"),
    ]
}
