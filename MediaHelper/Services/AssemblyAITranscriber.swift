import Foundation

/// Cloud transcription via AssemblyAI's v2 API.
///
/// Flow (three hops):
///   1. `POST /v2/upload`  — stream the audio bytes up, get back a URL.
///   2. `POST /v2/transcript` — kick off a transcription job with that
///      URL, optionally enabling `speaker_labels`.
///   3. `GET  /v2/transcript/{id}` — poll until `status == "completed"`.
///
/// Speaker labels are exposed on AssemblyAI as `utterances` (one entry
/// per speaker turn, each with `start`/`end`/`speaker`/`text`). When
/// diarization is off we fall back to the `words` array and glue words
/// into ~8-second segments for subtitle timing.
///
/// Translation is not handled here — AssemblyAI's v2 API doesn't have an
/// inline translate flag, it expects a follow-up LeMUR call. The factory
/// never hands this backend a request with `translateToEnglish == true`
/// because the capability matrix excludes it.
final class AssemblyAITranscriber: TranscriptionService {
    let backend: TranscriptionBackend = .assemblyAI

    private let apiKey: String
    private let urlSession: URLSession

    init(apiKey: String, urlSession: URLSession = .shared) {
        self.apiKey = apiKey
        self.urlSession = urlSession
    }

    func transcribe(audioFileURL: URL,
                    options: TranscriptionOptions,
                    progress: @Sendable @escaping (Double) -> Void) async throws -> TranscriptionResult {
        if options.translateToEnglish {
            throw TranscriptionError.backendRejected(
                "AssemblyAI backend doesn't support translation in this build. Pick OpenAI Whisper or WhisperKit for translated subtitles."
            )
        }

        progress(0.02)

        // 1. Upload
        let audioData = try Data(contentsOf: audioFileURL)
        let uploadURL = try await uploadAudio(audioData)
        progress(0.25)

        // 2. Create transcript job
        let jobId = try await createJob(audioURL: uploadURL,
                                        speakerLabels: options.speakerLabels)
        progress(0.35)

        // 3. Poll until done
        let result = try await pollJob(id: jobId, progress: progress)
        progress(1.0)
        return result
    }

    // MARK: - Upload

    private func uploadAudio(_ data: Data) async throws -> URL {
        guard let url = URL(string: "https://api.assemblyai.com/v2/upload") else {
            throw TranscriptionError.network("bad URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "Authorization")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.httpBody = data

        let (respData, resp): (Data, URLResponse)
        do {
            (respData, resp) = try await urlSession.data(for: req)
        } catch {
            throw TranscriptionError.network(error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let msg = String(data: respData, encoding: .utf8)
                ?? "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)"
            throw TranscriptionError.backendRejected(msg)
        }

        struct UploadResponse: Decodable { let upload_url: String }
        do {
            let decoded = try JSONDecoder().decode(UploadResponse.self, from: respData)
            guard let uploadURL = URL(string: decoded.upload_url) else {
                throw TranscriptionError.decoding("AssemblyAI returned a non-URL upload_url")
            }
            return uploadURL
        } catch let e as TranscriptionError { throw e }
        catch { throw TranscriptionError.decoding(error.localizedDescription) }
    }

    // MARK: - Create job

    private func createJob(audioURL: URL, speakerLabels: Bool) async throws -> String {
        guard let endpoint = URL(string: "https://api.assemblyai.com/v2/transcript") else {
            throw TranscriptionError.network("bad URL")
        }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "audio_url": audioURL.absoluteString,
            "speaker_labels": speakerLabels,
            "language_detection": true,
            "punctuate": true,
            "format_text": true
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (respData, resp): (Data, URLResponse)
        do {
            (respData, resp) = try await urlSession.data(for: req)
        } catch {
            throw TranscriptionError.network(error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let msg = String(data: respData, encoding: .utf8)
                ?? "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)"
            throw TranscriptionError.backendRejected(msg)
        }

        struct JobResponse: Decodable { let id: String }
        do {
            return try JSONDecoder().decode(JobResponse.self, from: respData).id
        } catch {
            throw TranscriptionError.decoding(error.localizedDescription)
        }
    }

    // MARK: - Poll

    /// AssemblyAI jobs usually finish in under half the audio duration;
    /// we poll every 3 seconds and bail after ~10 minutes to avoid
    /// hanging the UI indefinitely on a stuck job.
    private func pollJob(id: String,
                         progress: @Sendable @escaping (Double) -> Void) async throws -> TranscriptionResult {
        guard let endpoint = URL(string: "https://api.assemblyai.com/v2/transcript/\(id)") else {
            throw TranscriptionError.network("bad URL")
        }

        let deadline = Date().addingTimeInterval(10 * 60)
        var ticks = 0

        while Date() < deadline {
            try await Task.sleep(nanoseconds: 3 * 1_000_000_000)
            ticks += 1
            // Ease progress from 0.35 up toward 0.95 while waiting.
            progress(min(0.95, 0.35 + Double(ticks) * 0.02))

            var req = URLRequest(url: endpoint)
            req.setValue(apiKey, forHTTPHeaderField: "Authorization")
            let (data, resp): (Data, URLResponse)
            do {
                (data, resp) = try await urlSession.data(for: req)
            } catch {
                throw TranscriptionError.network(error.localizedDescription)
            }
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                continue
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = json["status"] as? String else {
                continue
            }

            switch status {
            case "completed":
                return try Self.decodeResult(from: json)
            case "error":
                throw TranscriptionError.backendRejected(
                    (json["error"] as? String) ?? "AssemblyAI reported an error"
                )
            default:
                continue // queued / processing
            }
        }

        throw TranscriptionError.backendRejected("Timed out waiting for AssemblyAI job.")
    }

    // MARK: - Decode

    /// Pull the fields we care about out of the completed-job JSON.
    /// When `utterances` is present (speaker_labels was on) we use it
    /// verbatim — each utterance becomes one segment. Otherwise we
    /// gather `words` into ~8-second segments so subtitles still have
    /// reasonable chunking.
    private static func decodeResult(from json: [String: Any]) throws -> TranscriptionResult {
        let language = json["language_code"] as? String

        if let utterances = json["utterances"] as? [[String: Any]], !utterances.isEmpty {
            let segs = utterances.compactMap { u -> TranscriptSegment? in
                guard let text = u["text"] as? String,
                      let start = (u["start"] as? Double) ?? (u["start"] as? Int).map(Double.init),
                      let end   = (u["end"]   as? Double) ?? (u["end"]   as? Int).map(Double.init)
                else { return nil }
                return TranscriptSegment(
                    start: start / 1000.0,
                    end: end / 1000.0,
                    text: text.trimmingCharacters(in: .whitespaces),
                    speaker: (u["speaker"] as? String).map { "Speaker \($0)" }
                )
            }
            return TranscriptionResult(language: language, isTranslation: false, segments: segs)
        }

        if let words = json["words"] as? [[String: Any]], !words.isEmpty {
            let segs = groupWordsIntoSegments(words)
            return TranscriptionResult(language: language, isTranslation: false, segments: segs)
        }

        // Final fallback: one big segment with the whole text.
        let text = (json["text"] as? String) ?? ""
        let duration = (json["audio_duration"] as? Double) ?? 0
        return TranscriptionResult(
            language: language,
            isTranslation: false,
            segments: [TranscriptSegment(start: 0, end: duration, text: text, speaker: nil)]
        )
    }

    private static func groupWordsIntoSegments(_ words: [[String: Any]],
                                               targetDuration: Double = 8) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        var buffer: [String] = []
        var bufStart: Double = .nan
        var bufEnd: Double = 0

        func flush() {
            guard !buffer.isEmpty, !bufStart.isNaN else { return }
            result.append(TranscriptSegment(
                start: bufStart / 1000.0,
                end: bufEnd / 1000.0,
                text: buffer.joined(separator: " "),
                speaker: nil
            ))
            buffer.removeAll()
            bufStart = .nan
            bufEnd = 0
        }

        for w in words {
            guard let text = w["text"] as? String else { continue }
            let start = (w["start"] as? Double) ?? Double((w["start"] as? Int) ?? 0)
            let end   = (w["end"]   as? Double) ?? Double((w["end"]   as? Int) ?? 0)
            if bufStart.isNaN { bufStart = start }
            buffer.append(text)
            bufEnd = end

            if (bufEnd - bufStart) / 1000.0 >= targetDuration {
                flush()
            }
        }
        flush()
        return result
    }
}
