import Foundation

/// A `TranscriptionService` turns an audio file on disk into a
/// `TranscriptionResult`. Concrete implementations:
///
///   - `WhisperKitTranscriber`    (on-device)
///   - `OpenAIWhisperTranscriber` (cloud)
///   - `AssemblyAITranscriber`    (cloud)
///
/// Pick one with `TranscriptionServiceFactory.make(for:)`.
protocol TranscriptionService {
    var backend: TranscriptionBackend { get }

    /// Run transcription. `options` is consulted for `translateToEnglish`
    /// and `speakerLabels`; other flags are ignored (they're for the
    /// pipeline stage after the service returns).
    ///
    /// `progress` is best-effort — some backends report it granularly,
    /// others only at 0 / 0.5 / 1.
    func transcribe(audioFileURL: URL,
                    options: TranscriptionOptions,
                    progress: @Sendable @escaping (Double) -> Void) async throws -> TranscriptionResult
}

/// Picks the right implementation at runtime. Checks API-key presence so
/// callers can fail cleanly rather than firing a broken network call.
enum TranscriptionServiceFactory {
    static func make(for backend: TranscriptionBackend) throws -> any TranscriptionService {
        switch backend {
        case .whisperKit:
            #if canImport(WhisperKit)
            return WhisperKitTranscriber()
            #else
            throw TranscriptionError.whisperKitUnavailable
            #endif

        case .openAIWhisper:
            guard let key = KeychainStore.load(.openAIAPIKey) else {
                throw TranscriptionError.missingAPIKey(.openAIWhisper)
            }
            return OpenAIWhisperTranscriber(apiKey: key)

        case .assemblyAI:
            guard let key = KeychainStore.load(.assemblyAIAPIKey) else {
                throw TranscriptionError.missingAPIKey(.assemblyAI)
            }
            return AssemblyAITranscriber(apiKey: key)
        }
    }

    /// True if the given backend could actually run right now (WhisperKit
    /// linked, or API key present). UI uses this to gray out picks.
    static func isAvailable(_ backend: TranscriptionBackend) -> Bool {
        switch backend {
        case .whisperKit:
            #if canImport(WhisperKit)
            return true
            #else
            return false
            #endif
        case .openAIWhisper:
            return KeychainStore.hasValue(for: .openAIAPIKey)
        case .assemblyAI:
            return KeychainStore.hasValue(for: .assemblyAIAPIKey)
        }
    }

    /// Best available backend, checked in preference order. Returns
    /// WhisperKit if linked, otherwise the first configured cloud
    /// backend, otherwise `.whisperKit` (so the UI has something to
    /// show with a clear "add the package" hint).
    static func defaultAvailableBackend() -> TranscriptionBackend {
        for candidate in [TranscriptionBackend.whisperKit, .openAIWhisper, .assemblyAI] {
            if isAvailable(candidate) { return candidate }
        }
        return .whisperKit
    }
}
