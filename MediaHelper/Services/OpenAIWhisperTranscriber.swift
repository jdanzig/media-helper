import Foundation

/// Cloud transcription via OpenAI's Whisper API (`whisper-1`).
///
/// Two endpoints we use:
///   - `/v1/audio/transcriptions` for same-language transcription.
///   - `/v1/audio/translations`   when `translateToEnglish` is requested
///     (always produces English, source is auto-detected).
///
/// We always ask for `response_format=verbose_json` so we get segment-
/// level timestamps back. The API enforces a 25 MB per-request file
/// limit; the caller (`AudioExtractor`) already compresses to m4a so we
/// rarely hit it, but we still sanity-check and surface a clean error.
///
/// Speaker diarization is not supported by this API — `speakerLabels`
/// is silently ignored.
final class OpenAIWhisperTranscriber: TranscriptionService {
    let backend: TranscriptionBackend = .openAIWhisper

    private let apiKey: String
    private let urlSession: URLSession
    private static let fileSizeLimit: Int64 = 25 * 1024 * 1024

    init(apiKey: String, urlSession: URLSession = .shared) {
        self.apiKey = apiKey
        self.urlSession = urlSession
    }

    func transcribe(audioFileURL: URL,
                    options: TranscriptionOptions,
                    progress: @Sendable @escaping (Double) -> Void) async throws -> TranscriptionResult {
        progress(0.02)

        // 25 MB guard — Whisper API rejects larger payloads outright.
        let attrs = try FileManager.default.attributesOfItem(atPath: audioFileURL.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        if size > Self.fileSizeLimit {
            throw TranscriptionError.fileTooLarge(bytes: size, limit: Self.fileSizeLimit)
        }

        let endpoint = options.translateToEnglish
            ? "https://api.openai.com/v1/audio/translations"
            : "https://api.openai.com/v1/audio/transcriptions"
        guard let url = URL(string: endpoint) else {
            throw TranscriptionError.network("bad URL")
        }

        let audioData = try Data(contentsOf: audioFileURL)
        let boundary = "----MediaHelper-\(UUID().uuidString)"

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)",
                     forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.appendMultipartField(named: "model", value: "whisper-1", boundary: boundary)
        body.appendMultipartField(named: "response_format", value: "verbose_json", boundary: boundary)
        // The transcriptions endpoint honors segment-granularity; the
        // translations endpoint also returns `segments` when verbose_json
        // is requested.
        body.appendMultipartField(
            named: "timestamp_granularities[]",
            value: "segment",
            boundary: boundary
        )
        body.appendMultipartFile(
            named: "file",
            filename: audioFileURL.lastPathComponent,
            mimeType: Self.mimeType(for: audioFileURL),
            fileData: audioData,
            boundary: boundary
        )
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        progress(0.3)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: req)
        } catch {
            throw TranscriptionError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.network("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw TranscriptionError.backendRejected(msg)
        }

        progress(0.85)

        struct VerboseSegment: Decodable {
            let start: Double
            let end: Double
            let text: String
        }
        struct VerboseResponse: Decodable {
            let language: String?
            let text: String?
            let segments: [VerboseSegment]?
        }

        do {
            let decoded = try JSONDecoder().decode(VerboseResponse.self, from: data)
            let segs = (decoded.segments ?? []).map {
                TranscriptSegment(
                    start: $0.start,
                    end: $0.end,
                    text: $0.text.trimmingCharacters(in: .whitespaces),
                    speaker: nil
                )
            }
            progress(1.0)
            return TranscriptionResult(
                language: options.translateToEnglish ? "en" : decoded.language,
                isTranslation: options.translateToEnglish,
                segments: segs
            )
        } catch {
            throw TranscriptionError.decoding(error.localizedDescription)
        }
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m4a", "mp4": return "audio/mp4"
        case "mp3":        return "audio/mpeg"
        case "wav":        return "audio/wav"
        case "flac":       return "audio/flac"
        case "ogg":        return "audio/ogg"
        default:           return "application/octet-stream"
        }
    }
}

// MARK: - Multipart helpers

private extension Data {
    mutating func appendMultipartField(named name: String, value: String, boundary: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append(value.data(using: .utf8)!)
        append("\r\n".data(using: .utf8)!)
    }

    mutating func appendMultipartFile(named name: String,
                                      filename: String,
                                      mimeType: String,
                                      fileData: Data,
                                      boundary: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        append(fileData)
        append("\r\n".data(using: .utf8)!)
    }
}
