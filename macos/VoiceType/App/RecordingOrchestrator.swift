import AppKit
import Core
import Foundation
import os

@MainActor
final class RecordingOrchestrator {

    /// `onDegraded` fires when an LLM pass fell back to the raw transcription
    /// because Groq rejected the request permanently (dead model, bad key). Only
    /// permanent rejections reach it — offline stays silent (G-025).
    typealias PipelineFactory = @MainActor @Sendable (_ apiKey: String, _ transcriptionEngine: String, _ refineEngine: String, _ translateEngine: String, _ whisperModels: WhisperModelManager, _ refineOptions: RefineOptions, _ onDegraded: @escaping @Sendable (Pipeline.Mode, PipelineError) -> Void) -> Pipeline

    /// Default factory exposed as a stored `@Sendable` closure so it can be
    /// captured into `Task { … }` blocks without losing `@Sendable` under
    /// strict concurrency. `@MainActor` is required because local adapters
    /// (`LocalRefiner`, `LocalTranslator`, `AIAvailability`) are `@MainActor`.
    static let defaultPipelineFactory: PipelineFactory = { apiKey, transcriptionEngine, refineEngine, translateEngine, whisperModels, refineOptions, onDegraded in
        let groq = GroqClient(apiKey: apiKey)
        let groqTranscriber = Transcriber(groq: groq)
        let groqFn: Pipeline.TranscribeFn = { try await groqTranscriber.transcribe(audio: $0, lang: $1, vocabulary: $2) }

        let transcribeFn: Pipeline.TranscribeFn
        switch transcriptionEngine {
        case "groq":
            // Groq-first; on connectivity failure (VPN 403, offline, timeout) paste
            // via the local model if it's already loaded. Never downloads here (G-032).
            let local = LocalTranscriber(manager: whisperModels)
            transcribeFn = FallbackTranscribe.make(
                primary: groqFn,
                fallback: { try await local.transcribe(audio: $0, lang: $1, vocabulary: $2) },
                isPrimaryReady: { true },
                shouldFallback: { error in
                    guard (error as? PipelineError)?.isConnectivityFailure == true else { return false }
                    return await whisperModels.isReady
                }
            )
        case "local":
            let local = LocalTranscriber(manager: whisperModels)
            transcribeFn = { try await local.transcribe(audio: $0, lang: $1, vocabulary: $2) }
        default: // "auto"
            let local = LocalTranscriber(manager: whisperModels)
            transcribeFn = FallbackTranscribe.make(
                primary: { try await local.transcribe(audio: $0, lang: $1, vocabulary: $2) },
                fallback: groqFn,
                isPrimaryReady: { true }
            )
        }

        // Refine/translate: local-first (FoundationModels) with Groq fallback,
        // then raw-text fallback if Groq is unreachable. Switch per engine config.
        let groqRefine: Pipeline.RefineFn = { try await Refiner(groq: groq, options: refineOptions).refine(text: $0) }
        let groqTranslate: Pipeline.TranslateFn = { try await Translator(groq: groq).translate(text: $0, target: $1) }

        let refineFn: Pipeline.RefineFn
        let translateFn: Pipeline.TranslateFn

        if #available(macOS 26, *) {
            let localRefiner = LocalRefiner(options: refineOptions)
            let localTranslator = LocalTranslator()
            let aiAvailable = AIAvailability().isAvailable   // captured once per take (MainActor read here)
            let localRefine: Pipeline.RefineFn = { try await localRefiner.refine(text: $0) }
            let localTranslate: Pipeline.TranslateFn = { try await localTranslator.translate(text: $0, target: $1) }

            switch refineEngine {
            case "groq":  refineFn = groqRefine
            case "local": refineFn = localRefine
            default:      refineFn = FallbackRefine.make(primary: localRefine, fallback: groqRefine,
                                                         isPrimaryAvailable: { aiAvailable }, timeoutSeconds: 5)
            }
            switch translateEngine {
            case "groq":  translateFn = groqTranslate
            case "local": translateFn = localTranslate
            default:      translateFn = FallbackTranslate.make(primary: localTranslate, fallback: groqTranslate,
                                                               isPrimaryAvailable: { aiAvailable }, timeoutSeconds: 5)
            }
        } else {
            // < macOS 26: no Apple Intelligence — always Groq.
            refineFn = groqRefine
            translateFn = groqTranslate
        }

        return Pipeline(
            transcribe: transcribeFn,
            refine: RawFallbackRefine.make(refine: refineFn, onDegraded: { onDegraded(.refine, $0) }),
            translate: RawFallbackTranslate.make(translate: translateFn, onDegraded: { onDegraded(.translate, $0) })
        )
    }

    let recorder: AudioRecorderProtocol
    let hud: HUDController
    let notifier: Notifier
    let soundFeedback: SoundFeedbackService
    let whisperModels: WhisperModelManager
    private var disconnectObserver: NSObjectProtocol?

    private var stateMachine: AppStateMachine?
    private var shortcutManager: ShortcutManager?
    let configStore: ConfigStore
    private(set) var paster: Paster
    var pipelineFactory: PipelineFactory
    let historyStore: HistoryStore
    let editObserver: EditObserver?

    private(set) var capturedMode: Mode = .refine
    var capturedTarget: FrontmostAppSnapshot?
    /// Text around the caret at hotkey-down (#41); fed to the refiner when
    /// `cursorContextEnabled` (#54). Not read at all while the toggle is off.
    var capturedContext: CursorContext?
    private var shortcutTask: Task<Void, Never>?
    private var resetTask: Task<Void, Never>?
    var recordingLevelTask: Task<Void, Never>?
    var recordingTickerTask: Task<Void, Never>?
    var pipelineTask: Task<Void, Never>?
    let logger = Logger(subsystem: "VoiceType", category: "RecordingOrchestrator")

    init(
        configStore: ConfigStore,
        historyStore: HistoryStore,
        notifier: Notifier,
        hudController: HUDController,
        paster: Paster? = nil,
        recorder: AudioRecorderProtocol? = nil,
        pipelineFactory: PipelineFactory? = nil,
        stateMachine: AppStateMachine? = nil,
        shortcutManager: ShortcutManager? = nil,
        soundFeedback: SoundFeedbackService? = nil,
        whisperModels: WhisperModelManager,
        editObserver: EditObserver? = nil
    ) {
        self.configStore = configStore
        self.historyStore = historyStore
        self.notifier = notifier
        self.hud = hudController
        self.paster = paster ?? Paster()
        self.recorder = recorder ?? AudioRecorder()
        self.pipelineFactory = pipelineFactory ?? RecordingOrchestrator.defaultPipelineFactory
        self.stateMachine = stateMachine
        self.shortcutManager = shortcutManager
        self.soundFeedback = soundFeedback ?? SoundFeedbackService()
        self.whisperModels = whisperModels
        self.editObserver = editObserver
    }

    func start() {
        if disconnectObserver == nil {
            disconnectObserver = NotificationCenter.default.addObserver(
                forName: .audioRecorderDisconnected,
                object: nil, queue: .main
            ) { [hud] _ in
                Task { @MainActor in
                    hud.hide()
                    let alert = NSAlert()
                    alert.messageText = "Microfone desconectado durante a gravação."
                    alert.runModal()
                }
            }
        }
        startShortcutTasks()
    }

    func wireShortcuts(stateMachine: AppStateMachine, shortcutManager: ShortcutManager) {
        stopShortcutTasks()
        self.stateMachine = stateMachine
        self.shortcutManager = shortcutManager
        startShortcutTasks()
    }

    func startShortcutTasks() {
        guard let sm = stateMachine, let mgr = shortcutManager else { return }
        guard shortcutTask == nil else { return }

        // Handled one at a time, in tap order: a release/cancel never runs
        // against a press whose recorder start is still in flight.
        shortcutTask = Task { [weak self] in
            for await event in mgr.events {
                switch event {
                case .pressed(let mode): await self?.handlePressed(mode, stateMachine: sm)
                case .released(let mode): await self?.handleReleased(mode, stateMachine: sm)
                case .cancelled(let mode): await self?.handleCancelled(mode, stateMachine: sm)
                case .locked: self?.hud.markLocked()
                }
            }
        }
        let events = sm.events
        resetTask = Task { [weak self] in
            for await change in events where change.to == .idle {
                await MainActor.run { self?.capturedMode = .refine }
            }
        }
    }

    func stopShortcutTasks() {
        shortcutTask?.cancel()
        resetTask?.cancel()
        shortcutTask = nil
        resetTask = nil
    }

    // Captures mode + frontmost app, then delegates to StartRecordingUseCase.
    // UI side-effects (HUD, notifications) live in the +Helpers extension.
    private func handlePressed(_ mode: Mode, stateMachine: AppStateMachine) async {
        capturedMode = mode
        capturedTarget = FocusedApp.snapshot()
        capturedContext = nil
        logger.info("press: mode=\(mode.rawValue, privacy: .public) target=\(self.capturedTarget?.bundleIdentifier ?? "(none)", privacy: .public)")

        // Cancel straggling pipeline BEFORE starting — its reset path must not fire against the new recording.
        pipelineTask?.cancel()
        pipelineTask = nil

        let cfg = (try? await configStore.load()) ?? AppConfig()

        let startUseCase = StartRecordingUseCase(
            recorder: AudioCaptureAdapter(recorder: recorder),
            state: StateMachineAdapter(machine: stateMachine)
        )

        let resolved = AudioInputResolver.resolveDeviceUID(
            explicit: cfg.recording.inputDeviceID,
            explicitLabel: cfg.recording.inputDeviceLabel,
            continuityFallbackEnabled: cfg.continuityFallbackEnabled
        )
        logger.info("device source=\(resolved.source.rawValue, privacy: .public) uid=\(resolved.uid ?? "(default)", privacy: .public)")

        do {
            try await startUseCase.execute(deviceUID: resolved.uid)
        } catch StartRecordingUseCase.Error.notIdle {
            return
        } catch StartRecordingUseCase.Error.permissionDenied {
            await notifyPermissionDenied()
            return
        } catch {
            await notifier.error(
                title: NotificationCopy.captureStartFailedTitle,
                body: NotificationCopy.captureStartFailedBody(error.localizedDescription)
            )
            return
        }

        // After the mic is open, never before: playing on Bluetooth output while
        // the input opens forces an A2DP→HFP switch mid-playback, which wedged
        // AVAudioEngine and hung the main thread (G-030). The click may land in
        // the first buffers; Whisper ignores it.
        if cfg.soundFeedbackEnabled {
            soundFeedback.playActivation()
        }

        hud.preset = WaveformColorPreset(rawValue: cfg.waveformPreset) ?? .aurora
        hud.style = HUDIndicatorStyle(rawValue: cfg.indicatorStyle) ?? .auto
        hud.show(state: .recording(level: -60, elapsed: 0))
        startRecordingHudTasks()

        // After the recorder is running, so a slow AX target never delays capture.
        // A voice note isn't written into the focused app — its context is noise.
        guard cfg.cursorContextEnabled, mode != .voiceNote else { return }
        capturedContext = CursorContextReader.read()
        logger.info("cursor context: \(self.capturedContext.map { "\($0.before.count)/\($0.selected.count)/\($0.after.count) chars" } ?? "none", privacy: .public)")
    }

    // Shortcut used as a modifier (extra key inside the cancel window): drop
    // the audio silently — no pipeline, no paste, no notification.
    private func handleCancelled(_ mode: Mode, stateMachine: AppStateMachine) async {
        logger.info("cancel: mode=\(mode.rawValue, privacy: .public) — shortcut used as modifier")
        await discardRecording(stateMachine: stateMachine)
    }

    private func handleReleased(_ mode: Mode, stateMachine: AppStateMachine) async {
        if mode != capturedMode {
            logger.warning("release mode (\(mode.rawValue, privacy: .public)) != captured (\(self.capturedMode.rawValue, privacy: .public))")
        }
        stopRecordingHudTasks()

        guard let audio = await captureAudio(stateMachine: stateMachine) else { return }

        hud.show(state: .processing)

        let cfg = (try? await configStore.load()) ?? AppConfig()
        // A voice note lands in Obsidian: refine style + history follow it, not the
        // focused app — so it needs no target (none when VoiceType itself is in front).
        let isVoiceNote = capturedMode == .voiceNote
        guard await preflight(cfg: cfg, requiresTarget: !isVoiceNote, stateMachine: stateMachine) else { return }
        let target = capturedTarget
        let bundleID = isVoiceNote ? DailyNote.obsidianBundleID : (target?.bundleIdentifier ?? "")
        let vaultKind = cfg.meetingVaultKind
        let vault = vaultKind == .openKnowledge
            ? OKVault.url(cfg.openKnowledgeVaultPath)
            : URL(fileURLWithPath: (cfg.meetingNotesFolder as NSString).expandingTildeInPath, isDirectory: true)

        var pipelineMode: Pipeline.Mode = (capturedMode == .translate) ? .translate : .refine
        if pipelineMode == .refine,
           RefineBypass.shouldBypass(bundleID: bundleID, disabledFor: cfg.refineBypassDisabledApps) {
            pipelineMode = .raw
            logger.info("refine bypassed for terminal \(bundleID, privacy: .public)")
        }
        // Lang/translateTarget hardcoded — Fase D only extracts use cases.
        let translateTarget: String? = (pipelineMode == .translate) ? "en" : nil

        let pipeline = pipelineFactory(
            cfg.groq.apiKey, cfg.transcriptionEngine, cfg.refineEngine, cfg.translateEngine, whisperModels,
            RefineOptions(vocabulary: cfg.vocabularyKeywords, style: RefineStyle.resolve(
                bundleID: bundleID,
                global: cfg.recording.refineStyle,
                categoryStyles: cfg.categoryStyles,
                appOverrides: cfg.appStyleOverrides
            ), cursorContext: cfg.cursorContextEnabled ? capturedContext : nil),
            { [weak self] degradedMode, error in
                Task { @MainActor in await self?.notifyDegraded(mode: degradedMode, error: error) }
            }
        )
        let runUseCase = RunPipelineUseCase(
            pipeline: PipelineRunnerAdapter(pipeline: pipeline),
            paster: isVoiceNote
                ? DailyNoteDeliveryAdapter(
                    vault: vault,
                    kind: vaultKind,
                    cliPath: cfg.claudeCLIPath,
                    rawTranscript: { await pipeline.lastRawTranscript },
                    onSaved: { @MainActor [weak self] title in
                        let daily = vaultKind == .openKnowledge
                            ? OKInbox.dailyURL(in: vault, for: Date())
                            : DailyNote.url(in: vault, for: Date())
                        let note = daily.deletingPathExtension().lastPathComponent
                        if let title {
                            await self?.notifier.success(title: NotificationCopy.voiceNoteSavedTitle(title), body: note)
                        } else {
                            await self?.notifier.info(title: NotificationCopy.voiceNoteUntitledTitle, body: note)
                        }
                    }
                )
                : PasterDeliveryAdapter(
                    paster: paster,
                    lookupTarget: { [target] _ in target },
                    onPasted: learnHook(cfg: cfg, mode: pipelineMode)
                ),
            history: HistoryRecorderAdapter(store: historyStore, cap: cfg.history.retentionCount)
        )

        let vocabulary = cfg.vocabularyKeywords.isEmpty ? nil : cfg.vocabularyKeywords

        pipelineTask?.cancel()
        pipelineTask = Task { [weak self] in
            do {
                try await runUseCase.execute(
                    audio: audio,
                    mode: pipelineMode,
                    lang: "pt",
                    translateTarget: translateTarget,
                    targetBundleId: bundleID,
                    historyEnabled: cfg.history.enabled,
                    historyCap: cfg.history.retentionCount,
                    autoEnter: cfg.autoEnterEnabled,
                    vocabulary: vocabulary
                )
            } catch {
                await self?.notifyPipelineFailure(error)
            }
            await self?.reset(stateMachine: stateMachine)
        }
    }

}
