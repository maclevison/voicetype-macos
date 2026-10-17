import Foundation

// Turns the per-track ASR output of a meeting into the merged
// "[mm:ss] Você: …" / "[mm:ss] Outros: …" (or "Outro 1", "Outro 2" once the
// system track is diarized) transcript fed to the summarizer.
// Pure: no WhisperKit, no I/O beyond the JSON checkpoint helpers.

/// One ASR segment, already placed on the meeting clock.
public struct MeetingUtterance: Codable, Sendable, Equatable {
    public var track: MeetingTrack
    /// Seconds since `MeetingManifest.startedAt`.
    public var start: Double
    public var end: Double
    public var text: String
    public var compressionRatio: Double
    /// 1-based remote speaker from system-track diarization; nil = unknown
    /// (mic track, diarization off/failed, or a single remote voice).
    public var speaker: Int?

    public init(track: MeetingTrack, start: Double, end: Double, text: String, compressionRatio: Double = 0, speaker: Int? = nil) {
        self.track = track
        self.start = start
        self.end = end
        self.text = text
        self.compressionRatio = compressionRatio
        self.speaker = speaker
    }

    /// Transcript label. The mic is always the user; a system voice never is.
    var label: String {
        if track == .mic { return "Você" }
        return speaker.map { "Outro \($0)" } ?? "Outros"
    }
}

/// One diarized stretch of the system track, on the meeting clock.
public struct MeetingSpeakerTurn: Codable, Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var speaker: String

    public init(start: Double, end: Double, speaker: String) {
        self.start = start
        self.end = end
        self.speaker = speaker
    }
}

public enum MeetingTranscript {
    /// Lowercased words without punctuation — shared by the hallucination and echo checks.
    public static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Strips Whisper special tokens (`<|en|>`, `<|0.00|>`, ...) and trims.
    public static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whisper's silence fillers (#74 spike 4): RMS can't separate them, these
    /// three text-level rules took ~200 mic segments down to ~10 real ones.
    public static func isHallucination(_ u: MeetingUtterance) -> Bool {
        let words = tokens(clean(u.text))
        if words.isEmpty { return true }
        if u.compressionRatio > 2.4 { return true }
        if words.count >= 6, Double(Set(words).count) / Double(words.count) < 0.3 { return true }
        // "E aí" / "Thank you" stretched over a whole window of silence.
        if u.end - u.start > 4, words.count <= 2 { return true }
        return false
    }

    /// Fraction of `mic`'s distinct words that also appear in `system`.
    /// Measured from the mic side (not Jaccard): an echo segment is often a
    /// slice of a longer system segment, and Jaccard would punish that.
    public static func echoScore(mic: String, system: String) -> Double {
        let m = Set(tokens(mic))
        guard !m.isEmpty else { return 0 }
        return Double(m.intersection(tokens(system)).count) / Double(m.count)
    }

    /// Drops mic segments that are just the speakers leaking into the mic
    /// (#74 spike 2: without AEC the mic transcript repeats the system one).
    /// ponytail: per-segment word containment; a genuine one-word reply that
    /// happens to be inside an overlapping system segment is dropped too.
    /// Upgrade path is real AEC (VPIO / WebRTC APM) on the mic track.
    public static func removeEcho(
        mic: [MeetingUtterance], system: [MeetingUtterance],
        window: Double = 2, threshold: Double = 0.6
    ) -> [MeetingUtterance] {
        mic.filter { m in
            // Union of every overlapping system segment: Whisper often splits a
            // sentence at a different point on each track ("…dias na" | "semana…").
            let nearby = system
                .filter { m.start <= $0.end + window && m.end >= $0.start - window }
                .map(\.text).joined(separator: " ")
            return echoScore(mic: m.text, system: nearby) < threshold
        }
    }

    /// Hallucination filter → echo dedupe → time-ordered, cleaned utterances.
    public static func process(_ utterances: [MeetingUtterance]) -> [MeetingUtterance] {
        let kept = utterances
            .filter { !isHallucination($0) }
            .map { u -> MeetingUtterance in var u = u; u.text = clean(u.text); return u }
        let system = kept.filter { $0.track == .system }
        let mic = removeEcho(mic: kept.filter { $0.track == .mic }, system: system)
        return (system + mic).sorted { ($0.start, $0.track == .mic ? 1 : 0) < ($1.start, $1.track == .mic ? 1 : 0) }
    }

    /// Tags each system utterance with the diarized speaker it overlaps most —
    /// or, with no overlap (Whisper and the diarizer cut time differently), the
    /// nearest turn within `maxGap` s — numbered 1, 2, … by first appearance.
    /// Mic utterances are never touched, so a remote voice can't become "Você".
    /// With fewer than two remote speakers the tags are dropped: "Outro 1"
    /// alone says less than "Outros".
    public static func assignSpeakers(
        _ utterances: [MeetingUtterance], turns: [MeetingSpeakerTurn], maxGap: Double = 3
    ) -> [MeetingUtterance] {
        var numbers: [String: Int] = [:]
        var tagged = utterances.map { u -> MeetingUtterance in
            var u = u
            u.speaker = nil
            guard u.track == .system else { return u }
            var best: (id: String, overlap: Double)?
            for t in turns {
                let overlap = min(u.end, t.end) - max(u.start, t.start)
                if overlap > 0, overlap > (best?.overlap ?? 0) { best = (t.speaker, overlap) }
            }
            if best == nil {
                let nearest = turns.min { gap(u, $0) < gap(u, $1) }
                if let nearest, gap(u, nearest) <= maxGap { best = (nearest.speaker, 0) }
            }
            guard let id = best?.id else { return u }
            u.speaker = numbers[id] ?? {
                numbers[id] = numbers.count + 1
                return numbers.count
            }()
            return u
        }
        if numbers.count < 2 {
            tagged = tagged.map { var u = $0; u.speaker = nil; return u }
        }
        return tagged
    }

    private static func gap(_ u: MeetingUtterance, _ t: MeetingSpeakerTurn) -> Double {
        max(t.start - u.end, u.start - t.end, 0)
    }

    /// `[mm:ss] Você: …` lines, consecutive turns of the same speaker coalesced.
    /// Input must already be processed (clean + ordered).
    public static func render(_ utterances: [MeetingUtterance]) -> String {
        var lines: [String] = []
        var last: String?
        for u in utterances {
            if u.label == last, !lines.isEmpty {
                lines[lines.count - 1] += " " + u.text
            } else {
                let s = max(0, Int(u.start))
                lines.append(String(format: "[%02d:%02d] %@: %@", s / 60, s % 60, u.label, u.text))
            }
            last = u.label
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Checkpoints

/// Progress of the post-capture pipeline, persisted next to the manifest so a
/// crash / quit / sleep never forces re-transcribing (#74 spike 5).
public struct MeetingPipelineState: Codable, Sendable, Equatable {
    public static let transcriptFileName = "transcript.json"
    public static let stateFileName = "pipeline.json"

    /// Stable across retries so the note writer overwrites instead of duplicating.
    public var noteID: UUID
    public var notePath: String?
    public var transcriptPath: String?
    /// False when the note was written with "Resumo indisponível" — a reprocess
    /// should try the summary again.
    public var summarized: Bool

    // OpenKnowledge mode. Optional so an older `pipeline.json` still decodes.
    // The paths are vault-relative and only mean something with `okVault`.
    /// The vault the meeting was approved into.
    public var okVault: OKVaultIdentity?
    public var okProject: String?
    public var okRecordPath: String?
    public var okTranscriptPath: String?
    /// The approval proposal was built (counts as processed for retention).
    public var okProcessed: Bool?

    public init(
        noteID: UUID = UUID(), notePath: String? = nil, transcriptPath: String? = nil, summarized: Bool = false,
        okVault: OKVaultIdentity? = nil, okProject: String? = nil, okRecordPath: String? = nil,
        okTranscriptPath: String? = nil, okProcessed: Bool? = nil
    ) {
        self.noteID = noteID
        self.notePath = notePath
        self.transcriptPath = transcriptPath
        self.summarized = summarized
        self.okVault = okVault
        self.okProject = okProject
        self.okRecordPath = okRecordPath
        self.okTranscriptPath = okTranscriptPath
        self.okProcessed = okProcessed
    }
}
