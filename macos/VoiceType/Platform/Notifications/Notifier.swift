import Foundation
import Observation
import UserNotifications
import os.log

/// Seam over `UNUserNotificationCenter` so tests can stub the center
/// without involving the real notification daemon.
protocol UserNotificationCenter: Sendable {
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
}

extension UNUserNotificationCenter: UserNotificationCenter {}

/// Wrapper over `UNUserNotificationCenter` providing error/info/success
/// helpers with pt-BR copy and silent fallback when auth is denied.
///
/// Difference from Electron's `notify.ts`: this implementation dedupes
/// identical (level+title+body) within a 5 s window. Spec §14 only requires
/// the three-level wrapper; the dedupe is a Phase 8 improvement to avoid
/// notification spam during error loops.
@MainActor
@Observable
final class Notifier {
    private let center: UserNotificationCenter
    private let log = Logger(subsystem: "com.voicetype.app", category: "notifier")
    private let now: () -> Date
    private(set) var authorized: Bool = false
    /// The authorization request, shared by every `bootstrap()` caller.
    private var bootstrapTask: Task<Void, Never>?

    /// Callback fired whenever the cached authorization state changes.
    /// `PermissionsChecker` consumes this to surface notification status in
    /// the Settings → Startup row.
    var onAuthChanged: ((Bool) -> Void)?

    private struct DedupeKey: Hashable {
        let level: String
        let title: String
        let body: String
    }

    private var lastEmittedAt: [DedupeKey: Date] = [:]
    private let dedupeWindow: TimeInterval = 5

    init(center: UserNotificationCenter, now: @escaping () -> Date) {
        self.center = center
        self.now = now
    }

    /// Convenience init used by `AppDependencies` for the live production graph.
    /// Wraps `UNUserNotificationCenter.current()` (the only Apple-mandated
    /// singleton we still touch).
    convenience init() {
        self.init(center: UNUserNotificationCenter.current(), now: Date.init)
    }

    /// Called once at app launch. Idempotent: a call while the request is
    /// still in flight waits for it, so whoever awaits `bootstrap()` before
    /// emitting sees the final `authorized`.
    func bootstrap() async {
        if let bootstrapTask {
            log.info("bootstrap skipped — already requested; waiting for it")
            await bootstrapTask.value
            return
        }
        let task = Task { await requestAuthorization() }
        bootstrapTask = task
        await task.value
    }

    private func requestAuthorization() async {
        log.info("bootstrap start: requesting [.alert, .sound]")
        do {
            authorized = try await center.requestAuthorization(options: [.alert, .sound])
            log.info("bootstrap result: authorized=\(self.authorized, privacy: .public)")
        } catch {
            authorized = false
            log.error("requestAuthorization failed: \(error.localizedDescription, privacy: .public)")
        }
        onAuthChanged?(authorized)
    }

    /// Backwards-name alias for the design spec's `requestAuth()` surface.
    func requestAuth() async { await bootstrap() }

    func error(title: String, body: String) async {
        await emit(level: "error", title: title, body: "❌ \(title) — \(body)", originalTitle: title, originalBody: body)
    }

    /// `category` attaches a registered `UNNotificationCategory` (action buttons).
    func info(title: String, body: String, category: String? = nil) async {
        await emit(level: "info", title: title, body: "\(title) — \(body)", originalTitle: title, originalBody: body, category: category)
    }

    func success(title: String, body: String) async {
        await emit(level: "success", title: title, body: "✓ \(title) — \(body)", originalTitle: title, originalBody: body)
    }

    private func emit(level: String, title: String, body: String, originalTitle: String, originalBody: String, category: String? = nil) async {
        guard authorized else {
            log.info("[\(level, privacy: .public)] suppressed (no auth): \(originalTitle, privacy: .public) — \(originalBody, privacy: .public)")
            return
        }
        let key = DedupeKey(level: level, title: originalTitle, body: originalBody)
        let nowDate = now()
        if let last = lastEmittedAt[key], nowDate.timeIntervalSince(last) < dedupeWindow {
            log.debug("dedupe drop [\(level, privacy: .public)] \(originalTitle, privacy: .public)")
            return
        }
        gcOldEntries(now: nowDate)
        lastEmittedAt[key] = nowDate

        let content = UNMutableNotificationContent()
        content.title = "VoiceType"
        content.body = body
        if let category { content.categoryIdentifier = category }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        do {
            try await center.add(request)
        } catch {
            log.error("center.add failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func gcOldEntries(now: Date) {
        if lastEmittedAt.count > 64 {
            lastEmittedAt = lastEmittedAt.filter { now.timeIntervalSince($0.value) < dedupeWindow }
        }
    }
}
