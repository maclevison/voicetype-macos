import Testing
import Foundation
@testable import Core

@Suite("MeetingManifest")
struct MeetingManifestTests {
    @Test func segmentFileNamesArePaddedPerTrack() {
        #expect(MeetingManifest.segmentFileName(track: .system, index: 1) == "system-001.caf")
        #expect(MeetingManifest.segmentFileName(track: .mic, index: 12) == "mic-012.caf")
    }

    @Test func directoryNameUsesLocalTime() {
        let date = Date(timeIntervalSince1970: 1_791_991_812) // 2026-10-14 15:30:12 UTC
        let utc = TimeZone(identifier: "UTC")!
        #expect(MeetingManifest.directoryName(for: date, timeZone: utc) == "2026-10-14_153012")
    }

    @Test func openSegmentNumbersEachTrackIndependently() {
        var m = MeetingManifest(id: "x", startedAt: Date())
        let s1 = m.openSegment(track: .system, sampleRate: 48_000, channels: 1, at: Date())
        let m1 = m.openSegment(track: .mic, sampleRate: 24_000, channels: 1, at: Date())
        let s2 = m.openSegment(track: .system, sampleRate: 24_000, channels: 1, at: Date())
        #expect([s1.fileName, m1.fileName, s2.fileName] == ["system-001.caf", "mic-001.caf", "system-002.caf"])
        #expect(m.segments.count == 3)
    }

    @Test func firstSampleAndCloseAreSetOnce() {
        var m = MeetingManifest(id: "x", startedAt: Date())
        let s = m.openSegment(track: .mic, sampleRate: 48_000, channels: 1, at: Date(timeIntervalSince1970: 0))
        m.markFirstSample(fileName: s.fileName, at: Date(timeIntervalSince1970: 1))
        m.markFirstSample(fileName: s.fileName, at: Date(timeIntervalSince1970: 2))
        m.closeSegment(fileName: s.fileName, at: Date(timeIntervalSince1970: 10))
        m.closeSegment(fileName: s.fileName, at: Date(timeIntervalSince1970: 20))
        #expect(m.segments[0].firstSampleAt == Date(timeIntervalSince1970: 1))
        #expect(m.segments[0].closedAt == Date(timeIntervalSince1970: 10))
    }

    @Test func roundTripKeepsSubSecondPrecision() throws {
        var m = MeetingManifest(id: "2026-10-14_153012", startedAt: Date(timeIntervalSince1970: 1_791_991_812.25))
        let s = m.openSegment(track: .system, sampleRate: 24_000, channels: 1, at: Date(timeIntervalSince1970: 1_791_991_812.5))
        m.markFirstSample(fileName: s.fileName, at: Date(timeIntervalSince1970: 1_791_991_812.625))
        m.endedAt = Date(timeIntervalSince1970: 1_791_995_000.125)
        m.platform = "teams"
        let decoded = try MeetingManifest.decode(m.encoded())
        #expect(decoded == m)
    }

    @Test func manifestWithoutPlatformStillDecodes() throws {
        let json = #"{"version":1,"id":"x","startedAt":"2026-10-14T15:30:12.000Z","segments":[]}"#
        #expect(try MeetingManifest.decode(Data(json.utf8)).platform == nil)
    }
}

@Suite("MeetingAudioRetention")
struct MeetingAudioRetentionTests {
    static let now = Date(timeIntervalSince1970: 1_791_999_000)
    static let day: TimeInterval = 86_400
    static let noted = MeetingPipelineState(notePath: "/vault/x.md")

    static func manifest(ageDays: Double) -> MeetingManifest {
        MeetingManifest(id: "x", startedAt: now.addingTimeInterval(-ageDays * day))
    }

    @Test func expiresOnlyOldMeetingsWithANote() {
        #expect(MeetingAudioRetention.isExpired(Self.manifest(ageDays: 8), state: Self.noted, now: Self.now, days: 7))
        // Unsummarized note still counts.
        #expect(MeetingAudioRetention.isExpired(Self.manifest(ageDays: 8), state: .init(notePath: "/n.md", summarized: false), now: Self.now, days: 7))
        #expect(!MeetingAudioRetention.isExpired(Self.manifest(ageDays: 6.9), state: Self.noted, now: Self.now, days: 7))
        #expect(!MeetingAudioRetention.isExpired(Self.manifest(ageDays: 30), state: nil, now: Self.now, days: 7))
        #expect(!MeetingAudioRetention.isExpired(Self.manifest(ageDays: 30), state: MeetingPipelineState(), now: Self.now, days: 7))
    }

    @Test func okProcessedMeetingAudioExpires() {
        #expect(MeetingAudioRetention.isExpired(Self.manifest(ageDays: 8), state: MeetingPipelineState(okProcessed: true), now: Self.now, days: 7))
        #expect(!MeetingAudioRetention.isExpired(Self.manifest(ageDays: 8), state: MeetingPipelineState(okProcessed: false), now: Self.now, days: 7))
        #expect(!MeetingAudioRetention.isExpired(Self.manifest(ageDays: 8), state: MeetingPipelineState(), now: Self.now, days: 7))
    }

    @Test func zeroOrNegativeDaysKeepsForever() {
        for days in [0, -1] {
            #expect(!MeetingAudioRetention.isExpired(Self.manifest(ageDays: 365), state: Self.noted, now: Self.now, days: days))
        }
    }

    @Test func purgeDeletesOnlyCafOfExpiredMeetings() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: base) }
        func meeting(_ name: String, ageDays: Double, state: MeetingPipelineState?) throws -> URL {
            let dir = base.appendingPathComponent(name)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Self.manifest(ageDays: ageDays).encoded().write(to: dir.appendingPathComponent(MeetingManifest.fileName))
            if let state { try JSONEncoder().encode(state).write(to: dir.appendingPathComponent(MeetingPipelineState.stateFileName)) }
            for f in ["system-001.caf", "mic-001.caf", MeetingPipelineState.transcriptFileName] {
                try Data("x".utf8).write(to: dir.appendingPathComponent(f))
            }
            return dir
        }
        let old = try meeting("old", ageDays: 10, state: Self.noted)
        let fresh = try meeting("fresh", ageDays: 1, state: Self.noted)
        let noNote = try meeting("nonote", ageDays: 10, state: nil)

        let deleted = MeetingAudioRetention.purge(base: base, now: Self.now, days: 7)
        #expect(Set(deleted.map(\.lastPathComponent)) == ["system-001.caf", "mic-001.caf"])
        #expect(Set(try fm.contentsOfDirectory(atPath: old.path)) == [
            MeetingManifest.fileName, MeetingPipelineState.stateFileName, MeetingPipelineState.transcriptFileName,
        ])
        #expect(fm.fileExists(atPath: fresh.appendingPathComponent("mic-001.caf").path))
        #expect(fm.fileExists(atPath: noNote.appendingPathComponent("mic-001.caf").path))
    }
}

@Suite("MeetingCaptureRate")
struct MeetingCaptureRateTests {
    @Test func prefersAggregateNominalRate() {
        #expect(MeetingCaptureRate.writeRate(aggregateNominal: 24_000, tapReported: 48_000) == 24_000)
    }

    @Test func fallsBackToTapRateWhenAggregateUnknown() {
        #expect(MeetingCaptureRate.writeRate(aggregateNominal: 0, tapReported: 48_000) == 48_000)
    }
}
