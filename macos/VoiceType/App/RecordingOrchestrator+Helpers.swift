import AppKit
import Core
import Foundation

// Side-effect helpers split out from `RecordingOrchestrator` to keep the main
// file focused on lifecycle + the press/release composition of use cases.
// All members below are `@MainActor` by virtue of the class declaration.
extension RecordingOrchestrator {

    // MARK: - HUD task lifecycle

    func startRecordingHudTasks() {
        recordingLevelTask = Task { @MainActor [hud, recorder] in
            for await db in recorder.levelStream {
                hud.update(level: db)
            }
        }
        recordingTickerTask = Task { @MainActor [hud] in
            let start = Date()
            while !Task.isCancelled {
                hud.update(elapsed: Date().timeIntervalSince(start))
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    func stopRecordingHudTasks() {
        recordingLevelTask?.cancel()
        recordingTickerTask?.cancel()
        recordingLevelTask = nil
        recordingTickerTask = nil
    }

    // MARK: - Learn from edits (#50)

    /// Post-paste hook, or nil — no AX reads at all — when the toggle is off.
    /// Translations (edits ≠ ASR misses) and auto-Enter (text already sent) skip.
    func learnHook(cfg: AppConfig, mode: Pipeline.Mode) -> (@Sendable (String) -> Void)? {
        guard cfg.learnFromEditsEnabled, mode != .translate, !cfg.autoEnterEnabled,
              let observer = editObserver else { return nil }
        let vocabulary = cfg.vocabularyKeywords
        return { text in Task { @MainActor in observer.observe(pasted: text, vocabulary: vocabulary) } }
    }

    // MARK: - Reset

    func reset(stateMachine: AppStateMachine) async {
        stopRecordingHudTasks()
        let current = await stateMachine.state
        if current == .processing {
            await stateMachine.send(.reset)
        } else if current == .recording {
            await stateMachine.send(.error(reason: "coordinator-reset"))
        }
        hud.hide()
        capturedTarget = nil
    }

    // Stops the recorder and throws the audio away (cancel paths). No-op
    // unless recording — a press rejected as notIdle must not reset the
    // pipeline that is still processing.
    func discardRecording(stateMachine: AppStateMachine) async {
        guard await stateMachine.state == .recording else { return }
        _ = try? await recorder.stop()
        await reset(stateMachine: stateMachine)
    }

    // MARK: - UI side-effects on use-case errors

    func notifyPermissionDenied() async {
        hud.show(state: .permissionDenied)
        Task { @MainActor [hud] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            hud.hide()
        }
        await notifier.error(
            title: NotificationCopy.micDeniedTitle,
            body: NotificationCopy.micDeniedBody
        )
    }

    // Runs StopRecordingUseCase and maps the typed errors to UI side-effects.
    // Returns nil if the orchestrator should bail out before processing.
    // Below this peak (Int16 full scale 32767) the capture is effectively
    // silent — ~-50 dBFS. Normal speech peaks far higher (-20…-6 dBFS); only a
    // muted mic or a wrong/idle default device (AirPods in A2DP) lands here.
    static let silencePeakThreshold = 100

    func captureAudio(stateMachine: AppStateMachine) async -> Data? {
        let stopUseCase = StopRecordingUseCase(
            recorder: AudioCaptureAdapter(recorder: recorder),
            state: StateMachineAdapter(machine: stateMachine)
        )
        do {
            let audio = try await stopUseCase.execute()
            let peak = WavEncoder.peakAmplitude(inWav: audio)
            if peak < Self.silencePeakThreshold {
                logger.info("captured audio is silent (peak=\(peak, privacy: .public)) — skipping pipeline")
                await notifier.error(
                    title: NotificationCopy.silentAudioTitle,
                    body: NotificationCopy.silentAudioBody
                )
                await reset(stateMachine: stateMachine)
                return nil
            }
            return audio
        } catch StopRecordingUseCase.Error.notRecording {
            return nil
        } catch StopRecordingUseCase.Error.tooShort {
            logger.info("audio too short — silent reset")
            await reset(stateMachine: stateMachine)
            return nil
        } catch {
            await notifier.error(
                title: NotificationCopy.captureStopFailedTitle,
                body: NotificationCopy.captureStopFailedBody(error.localizedDescription)
            )
            await reset(stateMachine: stateMachine)
            return nil
        }
    }

    // Checks that we have a Groq key when Groq is the only transcription path
    // (engine "groq") + (unless the take doesn't paste, like a voice note) a
    // capture target. Refine/translate without a key fall back to the raw text.
    // On failure notifies + resets and returns false so the caller bails out.
    func preflight(cfg: AppConfig, requiresTarget: Bool, stateMachine: AppStateMachine) async -> Bool {
        guard cfg.transcriptionEngine != "groq" || !cfg.groq.apiKey.isEmpty else {
            await notifier.error(
                title: NotificationCopy.missingGroqKeyTitle,
                body: NotificationCopy.missingGroqKeyBody
            )
            await reset(stateMachine: stateMachine)
            return false
        }
        guard !requiresTarget || capturedTarget != nil else {
            await notifier.error(
                title: NotificationCopy.noTargetTitle,
                body: NotificationCopy.noTargetBody
            )
            await reset(stateMachine: stateMachine)
            return false
        }
        return true
    }

    // Surfaces the various pipeline failure modes as the matching user-facing
    // notification. CancellationError is silenced (expected on
    // new-recording-cancels-old).
    func notifyPipelineFailure(_ error: Error) async {
        if error is CancellationError { return }
        switch error {
        case let pipelineError as PipelineError where pipelineError == .cancelled:
            await notifier.info(
                title: NotificationCopy.pipelineCancelledTitle,
                body: NotificationCopy.pipelineCancelledBody
            )
        case let pipelineError as PipelineError:
            await notifier.error(
                title: NotificationCopy.transcriptionErrorTitle,
                body: NotificationCopy.transcriptionErrorBody(ErrorPresenter.describe(pipelineError))
            )
        case let failed as DailyNoteDeliveryAdapter.WriteFailed:
            await notifier.error(
                title: NotificationCopy.voiceNoteFailedTitle,
                body: NotificationCopy.voiceNoteFailedBody(failed.detail)
            )
        case let pasterError as PasterError:
            await notifier.error(
                title: NotificationCopy.pasteFailedTitle,
                body: ErrorPresenter.describe(pasterError)
            )
        case LocalTranscriber.LocalError.notReady:
            await notifier.error(
                title: NotificationCopy.localModelNotReadyTitle,
                body: NotificationCopy.localModelNotReadyBody
            )
        default:
            await notifier.error(
                title: NotificationCopy.transcriptionErrorTitle,
                body: NotificationCopy.transcriptionErrorBody(error.localizedDescription)
            )
        }
    }

    // A permanent Groq rejection degrades *every* future dictation the same way
    // until the config is fixed, so the user is told. Being offline is not this:
    // RawFallback absorbs that silently on purpose, and notifying there would
    // fire on every take for as long as the network is down. See G-025.
    func notifyDegraded(mode: Pipeline.Mode, error: PipelineError) async {
        await notifier.error(
            title: mode == .translate
                ? NotificationCopy.translateDegradedTitle
                : NotificationCopy.refineDegradedTitle,
            body: NotificationCopy.degradedBody(ErrorPresenter.describe(error))
        )
    }
}
