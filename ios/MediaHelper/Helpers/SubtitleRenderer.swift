import Foundation

/// Converts `TranscriptSegment`s into subtitle-file formats.
///
/// SRT is the universal fallback (every player understands it). VTT is
/// what the web uses. We only emit SRT for now since the in-app outputs
/// are .srt files for sharing and the burn-in path consumes segments
/// directly without going through a subtitle file.
enum SubtitleRenderer {

    /// Serialize segments to SRT. Long segments are word-wrapped at
    /// `maxLineLength` characters so they don't overflow the screen.
    static func renderSRT(_ segments: [TranscriptSegment],
                          maxLineLength: Int = 42,
                          includeSpeaker: Bool = true) -> String {
        var out = ""
        for (i, seg) in segments.enumerated() {
            let cue = formatCue(index: i + 1,
                                segment: seg,
                                maxLineLength: maxLineLength,
                                includeSpeaker: includeSpeaker)
            out += cue + "\n"
        }
        return out
    }

    /// Write SRT to a temp file, return the URL.
    static func writeSRTFile(_ segments: [TranscriptSegment],
                             filename: String = "subtitles.srt",
                             includeSpeaker: Bool = true) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-" + filename)
        let content = renderSRT(segments, includeSpeaker: includeSpeaker)
        try content.data(using: .utf8)?.write(to: url)
        return url
    }

    // MARK: - Formatting

    private static func formatCue(index: Int,
                                  segment: TranscriptSegment,
                                  maxLineLength: Int,
                                  includeSpeaker: Bool) -> String {
        let prefix: String
        if includeSpeaker, let speaker = segment.speaker, !speaker.isEmpty {
            prefix = "[\(speaker)] "
        } else {
            prefix = ""
        }
        let wrapped = wrap(prefix + segment.text, width: maxLineLength)
        return """
        \(index)
        \(formatTimestamp(segment.start)) --> \(formatTimestamp(segment.end))
        \(wrapped)
        """
    }

    /// SRT timestamps are `HH:MM:SS,mmm`.
    static func formatTimestamp(_ t: TimeInterval) -> String {
        let safe = max(0, t)
        let hours = Int(safe) / 3600
        let minutes = (Int(safe) % 3600) / 60
        let seconds = Int(safe) % 60
        let millis = Int((safe - floor(safe)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, millis)
    }

    /// Greedy word-wrap to `width` characters per line, max 2 lines
    /// (SRT convention — more than two lines tends to overflow the
    /// safe area on small screens).
    private static func wrap(_ text: String, width: Int) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !words.isEmpty else { return text }

        var lines: [String] = []
        var current = ""
        for w in words {
            if current.isEmpty {
                current = w
            } else if current.count + 1 + w.count <= width {
                current += " " + w
            } else {
                lines.append(current)
                current = w
                if lines.count >= 2 {
                    // Dump any remaining words onto the second line.
                    break
                }
            }
        }
        if !current.isEmpty && lines.count < 2 {
            lines.append(current)
        } else if !current.isEmpty {
            lines[1] += " " + current
        }
        return lines.joined(separator: "\n")
    }
}
