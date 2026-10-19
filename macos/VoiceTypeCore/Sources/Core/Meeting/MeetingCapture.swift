import Foundation

// On-disk layout of one meeting capture: a directory with numbered CAF
// segments per track plus `manifest.json`. Every tap rebuild / mic restart
// opens a new segment; the manifest records when each one actually started
// so a later step can align the two tracks.

public enum MeetingTrack: String, Codable, Sendable {
    case system, mic
}

public struct MeetingSegment: Codable, Sendable, Equatable {
    public let track: MeetingTrack
    public let index: Int
    public let fileName: String
    public let sampleRate: Double
    public let channels: Int
    /// When the file was opened (before the device started).
    public let openedAt: Date
    /// When the first buffer was captured (from the buffer's host time) — use
    /// this one for alignment; nil if no audio ever arrived.
    public var firstSampleAt: Date?
    public var closedAt: Date?

    public init(track: MeetingTrack, index: Int, fileName: String, sampleRate: Double,
                channels: Int, openedAt: Date, firstSampleAt: Date? = nil, closedAt: Date? = nil) {
        self.track = track
        self.index = index
        self.fileName = fileName
        self.sampleRate = sampleRate
        self.channels = channels
        self.openedAt = openedAt
        self.firstSampleAt = firstSampleAt
        self.closedAt = closedAt
    }
}

public struct MeetingManifest: Codable, Sendable, Equatable {
    public static let fileName = "manifest.json"

    public var version = 1
    public let id: String
    public let startedAt: Date
    public var endedAt: Date?
    /// `MeetingApp.platform` of the call being recorded; nil when unknown
    /// (manual start with no meeting app on the mic, or pre-platform manifests).
    public var platform: String?
    public var segments: [MeetingSegment] = []

    public init(id: String, startedAt: Date, platform: String? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.platform = platform
    }

    /// `system-001.caf`, `mic-012.caf`.
    public static func segmentFileName(track: MeetingTrack, index: Int) -> String {
        String(format: "%@-%03d.caf", track.rawValue, index)
    }

    /// Directory / id for a meeting started at `date`, e.g. `2026-10-14_153012`.
    public static func directoryName(for date: Date, timeZone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02d_%02d%02d%02d",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// Appends the next segment of `track` and returns it.
    @discardableResult
    public mutating func openSegment(track: MeetingTrack, sampleRate: Double, channels: Int, at date: Date) -> MeetingSegment {
        let index = (segments.filter { $0.track == track }.map(\.index).max() ?? 0) + 1
        let segment = MeetingSegment(
            track: track, index: index,
            fileName: Self.segmentFileName(track: track, index: index),
            sampleRate: sampleRate, channels: channels, openedAt: date
        )
        segments.append(segment)
        return segment
    }

    public mutating func markFirstSample(fileName: String, at date: Date) {
        guard let i = segments.firstIndex(where: { $0.fileName == fileName }),
              segments[i].firstSampleAt == nil else { return }
        segments[i].firstSampleAt = date
    }

    public mutating func closeSegment(fileName: String, at date: Date) {
        guard let i = segments.firstIndex(where: { $0.fileName == fileName }),
              segments[i].closedAt == nil else { return }
        segments[i].closedAt = date
    }

    /// Fractional-second ISO 8601 dates: track alignment needs sub-second
    /// precision, which the stock `.iso8601` strategy drops.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(date.formatted(Self.dateStyle))
        }
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> MeetingManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dec in
            try dateStyle.parse(dec.singleValueContainer().decode(String.self))
        }
        return try decoder.decode(MeetingManifest.self, from: data)
    }

    private static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
}

/// Deletes the audio of old meetings that already have a note (#74). Keeps
/// `manifest.json`, `transcript.json` and `pipeline.json`, so a reprocess can
/// still redo the summary from the cached transcript.
public enum MeetingAudioRetention {
    /// True when `manifest`'s audio may go: retention on (`days > 0`), started
    /// more than `days` ago, and the pipeline already wrote a note (summarized
    /// or not) or, in OpenKnowledge mode, built its approval proposal (the
    /// transcript is cached; approving doesn't need the audio). In-progress
    /// recordings are never old enough.
    public static func isExpired(_ manifest: MeetingManifest, state: MeetingPipelineState?, now: Date, days: Int) -> Bool {
        guard days > 0, state?.notePath != nil || state?.okProcessed == true else { return false }
        return now.timeIntervalSince(manifest.startedAt) > TimeInterval(days) * 86_400
    }

    /// Removes the `.caf` files of every expired meeting under `base`; returns
    /// the deleted files. Unreadable manifests/states are skipped (kept).
    @discardableResult
    public static func purge(base: URL, now: Date = Date(), days: Int, fileManager: FileManager = .default) -> [URL] {
        guard days > 0, let dirs = try? fileManager.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { return [] }
        var deleted: [URL] = []
        for dir in dirs {
            guard let manifest = try? MeetingManifest.decode(Data(contentsOf: dir.appendingPathComponent(MeetingManifest.fileName))) else { continue }
            let state = try? JSONDecoder().decode(
                MeetingPipelineState.self, from: Data(contentsOf: dir.appendingPathComponent(MeetingPipelineState.stateFileName))
            )
            guard isExpired(manifest, state: state, now: now, days: days),
                  let files = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for file in files where file.pathExtension == "caf" {
                if (try? fileManager.removeItem(at: file)) != nil { deleted.append(file) }
            }
        }
        return deleted
    }
}

public enum MeetingCaptureRate {
    /// Sample rate to write the system track at. The aggregate device's nominal
    /// rate is the clock the tap is actually delivered on; the tap's own format
    /// can lie (AirPods in HFP: aggregate at 24 kHz, tap still says 48 kHz →
    /// file played back at 2× speed). The tap rate is only a fallback when the
    /// aggregate rate can't be read.
    public static func writeRate(aggregateNominal: Double, tapReported: Double) -> Double {
        aggregateNominal > 0 ? aggregateNominal : tapReported
    }
}
