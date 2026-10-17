import Foundation

public struct GroqConfig: Codable, Equatable, Sendable {
    public var apiKey: String

    public init(apiKey: String = "") {
        self.apiKey = apiKey
    }
}

public struct ShortcutConfig: Codable, Equatable, Sendable {
    public var refine: String
    public var translate: String

    public init(
        refine: String = "CommandOrControl+Shift+Space",
        translate: String = "CommandOrControl+Shift+E"
    ) {
        self.refine = refine
        self.translate = translate
    }
}

public struct RecordingConfig: Codable, Equatable, Sendable {
    public var language: String
    public var refineStyle: String
    public var inputDeviceID: String
    public var inputDeviceLabel: String

    public init(
        language: String = "pt-BR",
        refineStyle: String = "natural",
        inputDeviceID: String = "",
        inputDeviceLabel: String = ""
    ) {
        self.language = language
        self.refineStyle = refineStyle
        self.inputDeviceID = inputDeviceID
        self.inputDeviceLabel = inputDeviceLabel
    }
}

public struct TranslateConfig: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var target: String

    public init(enabled: Bool = false, target: String = "en-US") {
        self.enabled = enabled
        self.target = target
    }
}

public struct HistoryConfig: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var retentionCount: Int
    public var retentionDays: Int

    public init(
        enabled: Bool = true,
        retentionCount: Int = 100,
        retentionDays: Int = 7
    ) {
        self.enabled = enabled
        self.retentionCount = retentionCount
        self.retentionDays = retentionDays
    }
}

/// Single source of truth for VoiceType settings.
///
/// `schemaVersion` is the migration hook; current version is `2`.
/// Custom decoder detects v1 payloads (flat keys) and remaps silently.
/// The next save() after loading a v1 file will persist in v2 shape.
public struct AppConfig: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var groq: GroqConfig
    public var shortcuts: ShortcutConfig
    public var recording: RecordingConfig
    public var translate: TranslateConfig
    public var history: HistoryConfig
    public var startAtLogin: Bool
    public var showHud: Bool
    public var errorNotifications: Bool
    public var handsFreeEnabled: Bool
    public var waveformPreset: String
    public var indicatorStyle: String
    public var soundFeedbackEnabled: Bool
    public var autoEnterEnabled: Bool
    public var vocabularyKeywords: String
    public var transcriptionEngine: String
    public var refineEngine: String
    public var translateEngine: String
    public var continuityFallbackEnabled: Bool
    public var refineBypassDisabledApps: [String]
    public var appStyleOverrides: [String: String]
    public var categoryStyles: [String: String]
    public var cursorContextEnabled: Bool
    /// #50: observe the pasted range once after paste and suggest dictionary terms.
    public var learnFromEditsEnabled: Bool
    /// Window (ms) after a hold-shortcut press in which any extra keyDown
    /// cancels the recording — the user was reaching for another shortcut.
    public var shortcutCancelWindowMs: Int
    /// Key that, pressed while holding the shortcut, upgrades push-to-talk
    /// to hands-free (accelerator token, e.g. "Space"; empty = off).
    public var handsFreeUpgradeKey: String
    /// #74: folder the meeting notes are written to (`~` expanded at use).
    public var meetingNotesFolder: String
    /// #74: explicit path to the `claude` CLI; nil = look in the usual install dirs.
    public var claudeCLIPath: String?
    /// #74: org → client catalog used to classify meeting notes.
    public var meetingOrgs: [MeetingOrg]
    /// #74: what to do when a meeting app grabs the mic: "ask" (notification
    /// with a Gravar action), "auto" (record right away) or "off".
    public var meetingDetectionMode: String
    /// #74: days to keep a meeting's audio (`.caf`) once its note exists;
    /// 0 or negative = keep forever.
    public var meetingAudioRetentionDays: Int
    /// #79: hold shortcut that dictates an idea into today's daily note
    /// instead of pasting (accelerator syntax; empty = off).
    public var voiceNoteShortcut: String
    /// Where meetings and voice notes go: Obsidian (`meetingNotesFolder`) or
    /// the OpenKnowledge project at `openKnowledgeVaultPath`.
    public var meetingVaultKind: MeetingVaultKind
    /// Root of the OpenKnowledge project (the folder holding `.ok/`; `~` expanded at use; empty = not set).
    public var openKnowledgeVaultPath: String

    public init(
        schemaVersion: Int = 2,
        groq: GroqConfig = GroqConfig(),
        shortcuts: ShortcutConfig = ShortcutConfig(),
        recording: RecordingConfig = RecordingConfig(),
        translate: TranslateConfig = TranslateConfig(),
        history: HistoryConfig = HistoryConfig(),
        startAtLogin: Bool = false,
        showHud: Bool = true,
        errorNotifications: Bool = true,
        handsFreeEnabled: Bool = true,
        waveformPreset: String = "aurora",
        indicatorStyle: String = "auto",
        soundFeedbackEnabled: Bool = true,
        autoEnterEnabled: Bool = false,
        vocabularyKeywords: String = "",
        transcriptionEngine: String = "auto",
        refineEngine: String = "auto",
        translateEngine: String = "auto",
        continuityFallbackEnabled: Bool = true,
        refineBypassDisabledApps: [String] = [],
        appStyleOverrides: [String: String] = [:],
        categoryStyles: [String: String] = RefineStyle.defaultCategoryStyles,
        cursorContextEnabled: Bool = false,
        learnFromEditsEnabled: Bool = false,
        shortcutCancelWindowMs: Int = 1000,
        handsFreeUpgradeKey: String = "Space",
        meetingNotesFolder: String = "~/Documents/Meetings",
        claudeCLIPath: String? = nil,
        meetingOrgs: [MeetingOrg] = MeetingOrg.defaults,
        meetingDetectionMode: String = "ask",
        meetingAudioRetentionDays: Int = 7,
        voiceNoteShortcut: String = "Alt+N",
        meetingVaultKind: MeetingVaultKind = .obsidian,
        openKnowledgeVaultPath: String = ""
    ) {
        self.schemaVersion = schemaVersion
        self.groq = groq
        self.shortcuts = shortcuts
        self.recording = recording
        self.translate = translate
        self.history = history
        self.startAtLogin = startAtLogin
        self.showHud = showHud
        self.errorNotifications = errorNotifications
        self.handsFreeEnabled = handsFreeEnabled
        self.waveformPreset = waveformPreset
        self.indicatorStyle = indicatorStyle
        self.soundFeedbackEnabled = soundFeedbackEnabled
        self.autoEnterEnabled = autoEnterEnabled
        self.vocabularyKeywords = vocabularyKeywords
        self.transcriptionEngine = transcriptionEngine
        self.refineEngine = refineEngine
        self.translateEngine = translateEngine
        self.continuityFallbackEnabled = continuityFallbackEnabled
        self.refineBypassDisabledApps = refineBypassDisabledApps
        self.appStyleOverrides = appStyleOverrides
        self.categoryStyles = categoryStyles
        self.cursorContextEnabled = cursorContextEnabled
        self.learnFromEditsEnabled = learnFromEditsEnabled
        self.shortcutCancelWindowMs = shortcutCancelWindowMs
        self.handsFreeUpgradeKey = handsFreeUpgradeKey
        self.meetingNotesFolder = meetingNotesFolder
        self.claudeCLIPath = claudeCLIPath
        self.meetingOrgs = meetingOrgs
        self.meetingDetectionMode = meetingDetectionMode
        self.meetingAudioRetentionDays = meetingAudioRetentionDays
        self.voiceNoteShortcut = voiceNoteShortcut
        self.meetingVaultKind = meetingVaultKind
        self.openKnowledgeVaultPath = openKnowledgeVaultPath
    }

    // MARK: - Codable with v1→v2 migration

    // v2 encode keys (only the current shape is encoded)
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case groq, shortcuts, recording, translate, history
        case startAtLogin, showHud, errorNotifications, handsFreeEnabled
        case waveformPreset
        case indicatorStyle
        case soundFeedbackEnabled
        case autoEnterEnabled
        case vocabularyKeywords
        case transcriptionEngine
        case refineEngine
        case translateEngine
        case continuityFallbackEnabled
        case refineBypassDisabledApps
        case appStyleOverrides
        case categoryStyles
        case cursorContextEnabled
        case learnFromEditsEnabled
        case shortcutCancelWindowMs
        case handsFreeUpgradeKey
        case meetingNotesFolder
        case claudeCLIPath
        case meetingOrgs
        case meetingDetectionMode
        case meetingAudioRetentionDays
        case voiceNoteShortcut
        case meetingVaultKind
        case openKnowledgeVaultPath
    }

    // v1 flat keys used only during decode migration
    private enum LegacyCodingKeys: String, CodingKey {
        case schemaVersion
        case groqApiKey
        case globalShortcut, translateShortcut
        case translateEnabled, translateTargetLanguage
        case language, refineStyle, inputDeviceID, inputDeviceLabel
        case historyEnabled, historyRetentionCount, historyRetentionDays
        case startAtLogin, showHud, errorNotifications, handsFreeEnabled
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(groq, forKey: .groq)
        try c.encode(shortcuts, forKey: .shortcuts)
        try c.encode(recording, forKey: .recording)
        try c.encode(translate, forKey: .translate)
        try c.encode(history, forKey: .history)
        try c.encode(startAtLogin, forKey: .startAtLogin)
        try c.encode(showHud, forKey: .showHud)
        try c.encode(errorNotifications, forKey: .errorNotifications)
        try c.encode(handsFreeEnabled, forKey: .handsFreeEnabled)
        try c.encode(waveformPreset, forKey: .waveformPreset)
        try c.encode(indicatorStyle, forKey: .indicatorStyle)
        try c.encode(soundFeedbackEnabled, forKey: .soundFeedbackEnabled)
        try c.encode(autoEnterEnabled, forKey: .autoEnterEnabled)
        try c.encode(vocabularyKeywords, forKey: .vocabularyKeywords)
        try c.encode(transcriptionEngine, forKey: .transcriptionEngine)
        try c.encode(refineEngine, forKey: .refineEngine)
        try c.encode(translateEngine, forKey: .translateEngine)
        try c.encode(continuityFallbackEnabled, forKey: .continuityFallbackEnabled)
        try c.encode(refineBypassDisabledApps, forKey: .refineBypassDisabledApps)
        try c.encode(appStyleOverrides, forKey: .appStyleOverrides)
        try c.encode(categoryStyles, forKey: .categoryStyles)
        try c.encode(cursorContextEnabled, forKey: .cursorContextEnabled)
        try c.encode(learnFromEditsEnabled, forKey: .learnFromEditsEnabled)
        try c.encode(shortcutCancelWindowMs, forKey: .shortcutCancelWindowMs)
        try c.encode(handsFreeUpgradeKey, forKey: .handsFreeUpgradeKey)
        try c.encode(meetingNotesFolder, forKey: .meetingNotesFolder)
        try c.encodeIfPresent(claudeCLIPath, forKey: .claudeCLIPath)
        try c.encode(meetingOrgs, forKey: .meetingOrgs)
        try c.encode(meetingDetectionMode, forKey: .meetingDetectionMode)
        try c.encode(meetingAudioRetentionDays, forKey: .meetingAudioRetentionDays)
        try c.encode(voiceNoteShortcut, forKey: .voiceNoteShortcut)
        try c.encode(meetingVaultKind, forKey: .meetingVaultKind)
        try c.encode(openKnowledgeVaultPath, forKey: .openKnowledgeVaultPath)
    }

    public init(from decoder: Decoder) throws {
        let defaults = AppConfig()

        // Peek at schemaVersion using the v2 key set first; if missing treat as v1.
        let c2 = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c2.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.schemaVersion = 2  // always promote to current

        if version >= 2 {
            self.startAtLogin = try c2.decodeIfPresent(Bool.self, forKey: .startAtLogin) ?? defaults.startAtLogin
            self.showHud = try c2.decodeIfPresent(Bool.self, forKey: .showHud) ?? defaults.showHud
            self.errorNotifications = try c2.decodeIfPresent(Bool.self, forKey: .errorNotifications) ?? defaults.errorNotifications
            self.handsFreeEnabled = try c2.decodeIfPresent(Bool.self, forKey: .handsFreeEnabled) ?? defaults.handsFreeEnabled
            self.waveformPreset = try c2.decodeIfPresent(String.self, forKey: .waveformPreset) ?? defaults.waveformPreset
            self.indicatorStyle = try c2.decodeIfPresent(String.self, forKey: .indicatorStyle) ?? defaults.indicatorStyle
            self.soundFeedbackEnabled = try c2.decodeIfPresent(Bool.self, forKey: .soundFeedbackEnabled) ?? defaults.soundFeedbackEnabled
            self.autoEnterEnabled = try c2.decodeIfPresent(Bool.self, forKey: .autoEnterEnabled) ?? defaults.autoEnterEnabled
            self.vocabularyKeywords = try c2.decodeIfPresent(String.self, forKey: .vocabularyKeywords) ?? defaults.vocabularyKeywords
            self.transcriptionEngine =
                try c2.decodeIfPresent(String.self, forKey: .transcriptionEngine) ?? defaults.transcriptionEngine
            self.refineEngine =
                try c2.decodeIfPresent(String.self, forKey: .refineEngine) ?? defaults.refineEngine
            self.translateEngine =
                try c2.decodeIfPresent(String.self, forKey: .translateEngine) ?? defaults.translateEngine
            self.continuityFallbackEnabled = try c2.decodeIfPresent(Bool.self, forKey: .continuityFallbackEnabled) ?? defaults.continuityFallbackEnabled
            self.refineBypassDisabledApps = try c2.decodeIfPresent([String].self, forKey: .refineBypassDisabledApps) ?? defaults.refineBypassDisabledApps
            self.appStyleOverrides = try c2.decodeIfPresent([String: String].self, forKey: .appStyleOverrides) ?? defaults.appStyleOverrides
            self.categoryStyles = try c2.decodeIfPresent([String: String].self, forKey: .categoryStyles) ?? defaults.categoryStyles
            self.cursorContextEnabled = try c2.decodeIfPresent(Bool.self, forKey: .cursorContextEnabled) ?? defaults.cursorContextEnabled
            self.learnFromEditsEnabled = try c2.decodeIfPresent(Bool.self, forKey: .learnFromEditsEnabled) ?? defaults.learnFromEditsEnabled
            self.shortcutCancelWindowMs = try c2.decodeIfPresent(Int.self, forKey: .shortcutCancelWindowMs) ?? defaults.shortcutCancelWindowMs
            self.handsFreeUpgradeKey = try c2.decodeIfPresent(String.self, forKey: .handsFreeUpgradeKey) ?? defaults.handsFreeUpgradeKey
            self.meetingNotesFolder = try c2.decodeIfPresent(String.self, forKey: .meetingNotesFolder) ?? defaults.meetingNotesFolder
            self.claudeCLIPath = try c2.decodeIfPresent(String.self, forKey: .claudeCLIPath)
            self.meetingOrgs = try c2.decodeIfPresent([MeetingOrg].self, forKey: .meetingOrgs) ?? defaults.meetingOrgs
            self.meetingDetectionMode = try c2.decodeIfPresent(String.self, forKey: .meetingDetectionMode) ?? defaults.meetingDetectionMode
            self.meetingAudioRetentionDays = try c2.decodeIfPresent(Int.self, forKey: .meetingAudioRetentionDays) ?? defaults.meetingAudioRetentionDays
            self.voiceNoteShortcut = try c2.decodeIfPresent(String.self, forKey: .voiceNoteShortcut) ?? defaults.voiceNoteShortcut
            // Raw string, not MeetingVaultKind: an unknown value opens in Obsidian mode instead of throwing.
            self.meetingVaultKind = (try c2.decodeIfPresent(String.self, forKey: .meetingVaultKind))
                .flatMap(MeetingVaultKind.init(rawValue:)) ?? defaults.meetingVaultKind
            self.openKnowledgeVaultPath =
                try c2.decodeIfPresent(String.self, forKey: .openKnowledgeVaultPath) ?? defaults.openKnowledgeVaultPath
            self.groq = try c2.decodeIfPresent(GroqConfig.self, forKey: .groq) ?? defaults.groq
            self.shortcuts = try c2.decodeIfPresent(ShortcutConfig.self, forKey: .shortcuts) ?? defaults.shortcuts
            self.recording = try c2.decodeIfPresent(RecordingConfig.self, forKey: .recording) ?? defaults.recording
            self.translate = try c2.decodeIfPresent(TranslateConfig.self, forKey: .translate) ?? defaults.translate
            self.history = try c2.decodeIfPresent(HistoryConfig.self, forKey: .history) ?? defaults.history
        } else {
            // v1 → v2 migration: remap flat keys to nested sub-structs
            let c1 = try decoder.container(keyedBy: LegacyCodingKeys.self)
            self.startAtLogin = try c1.decodeIfPresent(Bool.self, forKey: .startAtLogin) ?? defaults.startAtLogin
            self.showHud = try c1.decodeIfPresent(Bool.self, forKey: .showHud) ?? defaults.showHud
            self.errorNotifications = try c1.decodeIfPresent(Bool.self, forKey: .errorNotifications) ?? defaults.errorNotifications
            self.handsFreeEnabled = try c1.decodeIfPresent(Bool.self, forKey: .handsFreeEnabled) ?? defaults.handsFreeEnabled
            self.waveformPreset = defaults.waveformPreset
            self.indicatorStyle = defaults.indicatorStyle
            self.soundFeedbackEnabled = defaults.soundFeedbackEnabled
            self.autoEnterEnabled = defaults.autoEnterEnabled
            self.vocabularyKeywords = defaults.vocabularyKeywords
            self.transcriptionEngine = defaults.transcriptionEngine
            self.refineEngine = defaults.refineEngine
            self.translateEngine = defaults.translateEngine
            self.continuityFallbackEnabled = defaults.continuityFallbackEnabled
            self.refineBypassDisabledApps = defaults.refineBypassDisabledApps
            self.appStyleOverrides = defaults.appStyleOverrides
            self.categoryStyles = defaults.categoryStyles
            self.cursorContextEnabled = defaults.cursorContextEnabled
            self.learnFromEditsEnabled = defaults.learnFromEditsEnabled
            self.shortcutCancelWindowMs = defaults.shortcutCancelWindowMs
            self.handsFreeUpgradeKey = defaults.handsFreeUpgradeKey
            self.meetingNotesFolder = defaults.meetingNotesFolder
            self.claudeCLIPath = defaults.claudeCLIPath
            self.meetingOrgs = defaults.meetingOrgs
            self.meetingDetectionMode = defaults.meetingDetectionMode
            self.meetingAudioRetentionDays = defaults.meetingAudioRetentionDays
            self.voiceNoteShortcut = defaults.voiceNoteShortcut
            self.meetingVaultKind = defaults.meetingVaultKind
            self.openKnowledgeVaultPath = defaults.openKnowledgeVaultPath
            self.groq = GroqConfig(
                apiKey: try c1.decodeIfPresent(String.self, forKey: .groqApiKey) ?? ""
            )
            self.shortcuts = ShortcutConfig(
                refine: try c1.decodeIfPresent(String.self, forKey: .globalShortcut)
                    ?? defaults.shortcuts.refine,
                translate: try c1.decodeIfPresent(String.self, forKey: .translateShortcut)
                    ?? defaults.shortcuts.translate
            )
            self.recording = RecordingConfig(
                language: try c1.decodeIfPresent(String.self, forKey: .language)
                    ?? defaults.recording.language,
                refineStyle: try c1.decodeIfPresent(String.self, forKey: .refineStyle)
                    ?? defaults.recording.refineStyle,
                inputDeviceID: try c1.decodeIfPresent(String.self, forKey: .inputDeviceID)
                    ?? defaults.recording.inputDeviceID,
                inputDeviceLabel: try c1.decodeIfPresent(String.self, forKey: .inputDeviceLabel)
                    ?? defaults.recording.inputDeviceLabel
            )
            self.translate = TranslateConfig(
                enabled: try c1.decodeIfPresent(Bool.self, forKey: .translateEnabled)
                    ?? defaults.translate.enabled,
                target: try c1.decodeIfPresent(String.self, forKey: .translateTargetLanguage)
                    ?? defaults.translate.target
            )
            self.history = HistoryConfig(
                enabled: try c1.decodeIfPresent(Bool.self, forKey: .historyEnabled)
                    ?? defaults.history.enabled,
                retentionCount: try c1.decodeIfPresent(Int.self, forKey: .historyRetentionCount)
                    ?? defaults.history.retentionCount,
                retentionDays: try c1.decodeIfPresent(Int.self, forKey: .historyRetentionDays)
                    ?? defaults.history.retentionDays
            )
        }
    }

    // MARK: - Validation

    public enum ValidationError: Error, Equatable, Sendable {
        case invalidGroqApiKey
        case shortcutCollision
        case historyRetentionOutOfRange
        case emptyShortcut

        public var message: String {
            switch self {
            case .invalidGroqApiKey:
                return "API key deve começar com \"gsk_\""
            case .shortcutCollision:
                return "Atalho de tradução não pode ser igual ao atalho principal."
            case .historyRetentionOutOfRange:
                return "Retenção de histórico deve estar entre 0 e 365 dias."
            case .emptyShortcut:
                return "Atalho não pode ficar vazio."
            }
        }
    }

    public func validate() throws {
        if !groq.apiKey.isEmpty && !groq.apiKey.hasPrefix("gsk_") {
            throw ValidationError.invalidGroqApiKey
        }
        if shortcuts.refine.isEmpty || shortcuts.translate.isEmpty {
            throw ValidationError.emptyShortcut
        }
        if history.retentionDays < 0 || history.retentionDays > 365 {
            throw ValidationError.historyRetentionOutOfRange
        }
        if translate.enabled && shortcuts.translate == shortcuts.refine {
            throw ValidationError.shortcutCollision
        }
    }
}
