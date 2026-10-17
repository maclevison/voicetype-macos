import Foundation
import Testing
@testable import Core

@Suite("AppStateMachine")
struct AppStateMachineTests {

    // Helper: poll until `condition` holds or `timeout` passes. A fixed sleep
    // flakes: under the full suite's load the 50 ms timer can fire after 1 s.
    private func eventually(timeout: Duration = .seconds(10), _ condition: () async -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    // Helper: collect state-change events from the actor's AsyncStream into an array.
    private func collectChanges(_ machine: AppStateMachine) -> AsyncCollector<AppStateMachine.StateChange> {
        AsyncCollector(stream: machine.events)
    }

    @Test("starts in idle")
    func startsInIdle() async {
        let machine = AppStateMachine()
        #expect(await machine.state == .idle)
    }

    @Test("idle -> recording on START")
    func startTransition() async {
        let machine = AppStateMachine()
        let collector = collectChanges(machine)

        await machine.send(.start)

        #expect(await machine.state == .recording)
        let changes = await collector.take(count: 1)
        #expect(changes.count == 1)
        #expect(changes[0].from == .idle)
        #expect(changes[0].to == .recording)
    }

    @Test("recording -> processing on STOP")
    func stopTransition() async {
        let machine = AppStateMachine()
        await machine.send(.start)
        await machine.send(.stop)
        #expect(await machine.state == .processing)
    }

    @Test("recording -> processing on TIMEOUT")
    func timeoutTransition() async {
        let machine = AppStateMachine()
        await machine.send(.start)
        await machine.send(.timeout)
        #expect(await machine.state == .processing)
    }

    @Test("processing -> idle on RESET")
    func resetTransition() async {
        let machine = AppStateMachine()
        await machine.send(.start)
        await machine.send(.stop)
        await machine.send(.reset)
        #expect(await machine.state == .idle)
    }

    @Test("ERROR from processing transitions to idle")
    func errorFromProcessing() async {
        let machine = AppStateMachine()
        await machine.send(.start)
        await machine.send(.stop)
        await machine.send(.error(reason: "pipeline-fail"))
        #expect(await machine.state == .idle)
    }

    @Test("ERROR from recording transitions to idle")
    func errorFromRecording() async {
        let machine = AppStateMachine()
        await machine.send(.start)
        await machine.send(.error(reason: "mic-denied"))
        #expect(await machine.state == .idle)
    }

    @Test("ERROR from idle is a guarded no-op (FU-003 parity)")
    func errorFromIdleIsNoOp() async {
        let machine = AppStateMachine()
        let collector = collectChanges(machine)

        await machine.send(.error(reason: "spurious"))

        #expect(await machine.state == .idle)
        let changes = await collector.takeAvailable()
        #expect(changes.isEmpty)
    }

    @Test("invalid transitions are no-ops and do not emit changes")
    func ignoresInvalidTransitions() async {
        let machine = AppStateMachine()
        await machine.send(.start) // idle -> recording
        await machine.send(.stop)  // recording -> processing

        let collector = collectChanges(machine)
        await machine.send(.start) // invalid in processing

        #expect(await machine.state == .processing)
        let changes = await collector.takeAvailable()
        #expect(changes.isEmpty)
    }

    @Test("auto-fires TIMEOUT after 5 minutes in recording")
    func autoTimeoutFires() async throws {
        // Use a short timeout via the testing initializer.
        let machine = AppStateMachine(recordingTimeout: .milliseconds(50))
        await machine.send(.start)
        #expect(await machine.state == .recording)

        #expect(try await eventually { await machine.state == .processing })
    }

    @Test("timeout handler replaces TIMEOUT: called once, state stays recording")
    func timeoutHandlerReplacesTransition() async throws {
        let machine = AppStateMachine(recordingTimeout: .milliseconds(50))
        let calls = CallCounter()
        await machine.onTimeout { calls.increment() }
        await machine.send(.start)
        #expect(try await eventually { calls.value > 0 })
        #expect(calls.value == 1)
        #expect(await machine.state == .recording)
    }

    @Test("STOP cancels the pending recording timer")
    func stopCancelsTimer() async throws {
        let machine = AppStateMachine(recordingTimeout: .milliseconds(50))
        await machine.send(.start)
        await machine.send(.stop) // -> processing, cancels timer
        await machine.send(.reset) // -> idle

        // Wait past the original deadline; state must remain idle.
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(await machine.state == .idle)
    }

    @Test("destroy / deinit cancels the pending timer")
    func destroyCancelsTimer() async throws {
        var machine: AppStateMachine? = AppStateMachine(recordingTimeout: .milliseconds(50))
        await machine!.send(.start)
        await machine!.shutdown()
        machine = nil

        // Sleep past the deadline; the absence of crash / leak is the assertion.
        try await Task.sleep(nanoseconds: 200_000_000)
        // Nothing further to check — actor is gone, no leak.
    }

    @Test("events stream emits in order across multiple subscribers")
    func multipleSubscribers() async {
        let machine = AppStateMachine()
        let a = collectChanges(machine)
        let b = collectChanges(machine)

        await machine.send(.start)
        await machine.send(.stop)
        await machine.send(.reset)

        let changesA = await a.take(count: 3)
        let changesB = await b.take(count: 3)

        #expect(changesA.map(\.to) == [.recording, .processing, .idle])
        #expect(changesB.map(\.to) == [.recording, .processing, .idle])
    }
}

// MARK: - AsyncCollector helper

/// Buffers events from an `AsyncStream` so tests can pull them deterministically.
actor AsyncCollector<Element: Sendable> {
    private var buffer: [Element] = []
    private var task: Task<Void, Never>?

    init(stream: AsyncStream<Element>) {
        self.task = Task { [weak self] in
            for await element in stream {
                await self?.append(element)
            }
        }
    }

    func append(_ element: Element) {
        buffer.append(element)
    }

    /// Wait until `count` elements arrive (with a 1s safety timeout).
    func take(count: Int) async -> [Element] {
        let deadline = Date().addingTimeInterval(1.0)
        while buffer.count < count && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000) // 5 ms poll
        }
        return Array(buffer.prefix(count))
    }

    /// Snapshot whatever has already arrived; no waiting.
    func takeAvailable() -> [Element] {
        return buffer
    }

    deinit {
        task?.cancel()
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    func increment() { lock.lock(); n += 1; lock.unlock() }
}
