@preconcurrency import AVFoundation
import AppKit
import Core
import CoreAudio
import os

/// Records a meeting as two independent tracks streamed to disk:
/// system audio (`SystemAudioCapture`) and microphone (`MicCapture`).
///
/// Layout: `~/Library/Application Support/VoiceType/Meetings/<id>/`
/// with `system-NNN.caf`, `mic-NNN.caf` and `manifest.json`. A new segment is
/// opened on every tap rebuild (default output / aggregate rate change, wake)
/// and every mic restart (engine config change, wake). Files are 16-bit PCM
/// CAF at the device's native rate — CAF has no 4 GB limit.
///
/// On stop the directory is handed to `MeetingProcessor` (transcript + summary
/// + note). `MeetingDetector` starts/stops it on its own when a meeting app
/// grabs/releases the mic (#74).
@MainActor
@Observable
final class MeetingRecorder {
    private(set) var isRecording = false
    /// True when `MeetingDetector` started this recording: only those stop
    /// on their own when the meeting ends; manual ones never do.
    private(set) var startedByDetection = false

    @ObservationIgnored private let configStore: ConfigStore
    @ObservationIgnored private let notifier: Notifier
    @ObservationIgnored private let processor: MeetingProcessor
    @ObservationIgnored private let system = SystemAudioCapture()
    @ObservationIgnored private let mic = MicCapture()
    @ObservationIgnored private var directory: URL?
    @ObservationIgnored private var manifest: MeetingManifest?
    @ObservationIgnored private var systemSegment: String?
    @ObservationIgnored private var micSegment: String?
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var systemRebuildTask: Task<Void, Never>?
    @ObservationIgnored private var micRestartTask: Task<Void, Never>?
    private static let log = Logger(subsystem: "VoiceType", category: "meeting")

    nonisolated static let baseDirectory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("VoiceType/Meetings", isDirectory: true)

    init(configStore: ConfigStore, notifier: Notifier, onPendingChanged: @escaping @Sendable () async -> Void) {
        self.configStore = configStore
        self.notifier = notifier
        self.processor = MeetingProcessor(configStore: configStore, notifier: notifier, onPendingChanged: onPendingChanged)
        system.onNeedsRebuild = { [weak self] in self?.scheduleSystemRebuild() }
        mic.onConfigurationChange = { [weak self] in self?.scheduleMicRestart() }
    }

    func toggle() {
        if isRecording { stop() } else { Task { await start() } }
    }

    /// `app`: the meeting the detector saw. A manual start (nil) scans the mic
    /// users once so the note still names the call's app when there is one.
    func start(detected app: MeetingApp? = nil) async {
        guard !isRecording else { return }
        isRecording = true
        startedByDetection = app != nil

        var platform = app?.platform
        if platform == nil {
            let selfPID = getpid()
            platform = await Task.detached(priority: .userInitiated) {
                MicUsers.meetingApps(excluding: selfPID).first?.platform
            }.value
            guard isRecording else { return } // stopped while scanning
        }

        let now = Date()
        let id = MeetingManifest.directoryName(for: now)
        let dir = Self.baseDirectory.appendingPathComponent(id, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            isRecording = false
            await notifier.error(title: "Gravação de reunião", body: "Não consegui criar a pasta: \(error.localizedDescription)")
            return
        }
        directory = dir
        manifest = MeetingManifest(id: id, startedAt: now, platform: platform)
        writeManifest()

        // Idle sleep would freeze the capture mid-meeting (#74 spikes 4/5).
        // Lid-close sleep still wins; the wake handler reopens segments.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Gravando reunião"
        )
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleWake() }
        }

        let systemOK = startSystem()
        let micOK = await startMic()
        guard isRecording else { return } // stopped while the mic was starting
        if !systemOK && !micOK {
            stop(notify: false)
            await notifier.error(title: "Gravação de reunião", body: "Não consegui capturar nem o áudio do sistema nem o microfone.")
        }
        Self.log.info("meeting recording started: \(dir.path, privacy: .public) system=\(systemOK) mic=\(micOK)")
    }

    func stop() { stop(notify: true) }

    private func stop(notify: Bool) {
        guard isRecording else { return }
        systemRebuildTask?.cancel()
        micRestartTask?.cancel()
        closeSystem()
        closeMic()
        manifest?.endedAt = Date()
        writeManifest()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        isRecording = false
        Self.log.info("meeting recording stopped: \(self.directory?.path ?? "-", privacy: .public)")
        if notify, let directory {
            Task { await processor.enqueue(directory) }
        }
    }

    /// Re-runs the pipeline on the most recent finished meeting; it resumes
    /// from its checkpoints (no re-transcription of segments already done).
    func reprocessLatest() {
        let fm = FileManager.default
        let current = isRecording ? directory?.lastPathComponent : nil
        // Directory names are sortable timestamps (`2026-10-14_153012`).
        let latest = ((try? fm.contentsOfDirectory(atPath: Self.baseDirectory.path)) ?? [])
            .filter { $0 != current && fm.fileExists(atPath: Self.baseDirectory.appendingPathComponent("\($0)/\(MeetingManifest.fileName)").path) }
            .max()
        guard let latest else {
            Task { await notifier.info(title: "Reprocessar reunião", body: "Nenhuma reunião gravada.") }
            return
        }
        let dir = Self.baseDirectory.appendingPathComponent(latest, isDirectory: true)
        Task {
            let cfg = (try? await configStore.load()) ?? AppConfig()
            // Reprocessing rebuilds the proposal and drops the approval window's progress.
            if cfg.meetingVaultKind == .openKnowledge, OKApprovalProgress.load(dir)?.hasEdits == true {
                let alert = NSAlert()
                alert.messageText = "Reprocessar e descartar as edições da aprovação pendente?"
                alert.addButton(withTitle: "Reprocessar")
                alert.addButton(withTitle: "Cancelar")
                NSApp.activate(ignoringOtherApps: true)
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            await processor.enqueue(dir)
        }
    }

    /// Deletes old meetings' audio per `meetingAudioRetentionDays` (launch;
    /// also runs after every processed meeting).
    func purgeOldAudio() {
        Task { await processor.enqueuePurge() }
    }

    // MARK: - System track

    @discardableResult
    private func startSystem() -> Bool {
        do {
            let format = try system.prepare()
            let (file, onFirstSample) = try openSegment(.system, format: format)
            try system.run(file: file, onFirstSample: onFirstSample)
            return true
        } catch {
            system.stop()
            closeSystemSegment()
            Self.log.error("system capture failed: \(String(describing: error), privacy: .public)")
            Task { await notifier.error(title: "Áudio do sistema", body: "Captura falhou: \(error)") }
            return false
        }
    }

    private func closeSystem() {
        system.stop()
        closeSystemSegment()
    }

    private func closeSystemSegment() {
        if let systemSegment { manifest?.closeSegment(fileName: systemSegment, at: Date()) }
        systemSegment = nil
        writeManifest()
    }

    /// Coalesces bursts (output change + rate change fire together) into one
    /// rebuild; retries once if the device isn't ready yet.
    private func scheduleSystemRebuild() {
        systemRebuildTask?.cancel()
        systemRebuildTask = Task { [weak self] in
            for delay in [0.3, 2.0] {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled, self.isRecording else { return }
                self.closeSystem()
                if self.startSystem() { return }
            }
        }
    }

    // MARK: - Mic track

    private func startMic() async -> Bool {
        guard await Self.micPermitted() else {
            Self.log.error("mic permission denied; recording system audio only")
            return false
        }
        let cfg = (try? await configStore.load()) ?? AppConfig()
        guard isRecording else { return false }
        let resolved = AudioInputResolver.resolveDeviceUID(
            explicit: cfg.recording.inputDeviceID,
            explicitLabel: cfg.recording.inputDeviceLabel,
            continuityFallbackEnabled: cfg.continuityFallbackEnabled
        )
        do {
            try await mic.start(deviceUID: resolved.uid) { [unowned self] format in
                try self.openSegment(.mic, format: format)
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            closeMicSegment()
            Self.log.error("mic capture failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private func closeMic() {
        mic.stop()
        closeMicSegment()
    }

    private func closeMicSegment() {
        if let micSegment { manifest?.closeSegment(fileName: micSegment, at: Date()) }
        micSegment = nil
        writeManifest()
    }

    private func scheduleMicRestart() {
        micRestartTask?.cancel()
        micRestartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.5))
            guard let self, !Task.isCancelled, self.isRecording else { return }
            Self.log.info("mic configuration changed → restart")
            self.closeMic()
            _ = await self.startMic()
        }
    }

    private static func micPermitted() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    // MARK: - Shared

    private func handleWake() {
        guard isRecording else { return }
        Self.log.info("wake → reopen meeting segments")
        scheduleSystemRebuild()
        scheduleMicRestart()
    }

    /// Opens the next segment of `track` in the manifest and its CAF file.
    private func openSegment(
        _ track: MeetingTrack, format: AVAudioFormat
    ) throws -> (AVAudioFile, @Sendable (UInt64) -> Void) {
        guard let directory, manifest != nil else { throw CancellationError() }
        let segment = manifest!.openSegment(
            track: track, sampleRate: format.sampleRate,
            channels: Int(format.channelCount), at: Date()
        )
        switch track {
        case .system: systemSegment = segment.fileName
        case .mic: micSegment = segment.fileName
        }
        writeManifest()

        // 16-bit on disk (half the size of float32); float32 in memory.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(
            forWriting: directory.appendingPathComponent(segment.fileName),
            settings: settings, commonFormat: .pcmFormatFloat32,
            interleaved: format.isInterleaved
        )

        let name = segment.fileName
        let onFirstSample: @Sendable (UInt64) -> Void = { [weak self] hostTime in
            // Host time of the first buffer → wall clock, for track alignment.
            let now = AudioGetCurrentHostTime()
            let delta = Double(AudioConvertHostTimeToNanos(now > hostTime ? now - hostTime : hostTime - now)) / 1e9
            let date = Date(timeIntervalSinceNow: now > hostTime ? -delta : delta)
            Task { @MainActor in
                self?.manifest?.markFirstSample(fileName: name, at: date)
                self?.writeManifest()
            }
        }
        return (file, onFirstSample)
    }

    private func writeManifest() {
        guard let manifest, let directory else { return }
        do {
            try manifest.encoded().write(to: directory.appendingPathComponent(MeetingManifest.fileName), options: .atomic)
        } catch {
            Self.log.error("manifest write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
