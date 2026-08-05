import Foundation

/// Produces the user-facing `.txt` transcript file.
///
/// Two rendering modes, picked automatically based on whether segments
/// carry speaker labels:
///
///   - "Speaker 1: Hello.\nSpeaker 2: Hi." when AssemblyAI returned
///     `utterances` with speaker diarization enabled.
///   - Timestamped paragraphs (`[00:00] text…`) otherwise.
///
/// We always include a brief header noting the source language and
/// whether the text is a translation, which is useful when the user
/// later opens the file without the original video handy.
enum TranscriptFormatter {

    static func render(_ result: TranscriptionResult) -> String {
        let hasSpeakers = result.segments.contains(where: { $0.speaker != nil })
        var out = ""

        let langLine: String = {
            if result.isTranslation { return "Translation (English)" }
            if let lang = result.language, !lang.isEmpty { return "Language: \(lang)" }
            return "Transcript"
        }()
        out += "# \(langLine)\n\n"

        if hasSpeakers {
            out += renderWithSpeakers(result.segments)
        } else {
            out += renderTimestamped(result.segments)
        }
        return out
    }

    /// Merge consecutive same-speaker segments into one paragraph so the
    /// output reads like a transcript rather than a cue sheet.
    private static func renderWithSpeakers(_ segments: [TranscriptSegment]) -> String {
        var out = ""
        var currentSpeaker: String? = nil
        var buffer: [String] = []

        func flush() {
            guard !buffer.isEmpty else { return }
            let speaker = currentSpeaker ?? "Speaker"
            out += "\(speaker): \(buffer.joined(separator: " "))\n\n"
            buffer.removeAll()
        }

        for seg in segments {
            if seg.speaker != currentSpeaker {
                flush()
                currentSpeaker = seg.speaker
            }
            buffer.append(seg.text)
        }
        flush()
        return out
    }

    private static func renderTimestamped(_ segments: [TranscriptSegment]) -> String {
        var out = ""
        for seg in segments {
            out += "[\(shortTimestamp(seg.start))] \(seg.text)\n"
        }
        return out
    }

    /// `MM:SS` for clips under an hour, `HH:MM:SS` otherwise.
    private static func shortTimestamp(_ t: TimeInterval) -> String {
        let safe = max(0, t)
        let h = Int(safe) / 3600
        let m = (Int(safe) % 3600) / 60
        let s = Int(safe) % 60
        return h == 0
            ? String(format: "%02d:%02d", m, s)
            : String(format: "%02d:%02d:%02d", h, m, s)
    }

    /// Write the rendered transcript to a temp `.txt` file.
    static func writeTranscriptFile(_ result: TranscriptionResult,
                                    filename: String = "transcript.txt") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-" + filename)
        try render(result).data(using: .utf8)?.write(to: url)
        return url
    }
}
