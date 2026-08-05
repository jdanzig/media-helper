import Foundation

/// Which engine produces transcripts / subtitles.
///
/// Capabilities drive which options get grayed out in the UI — see
/// `TranscriptionBackend.capabilities`. The `isAvailable` check folds in
/// whether the required API key (for the cloud backends) has been
/// configured in Settings.
enum TranscriptionBackend: String, CaseIterable, Identifiable, Hashable {
    case whisperKit      // On-device Whisper via WhisperKit SPM package.
    case openAIWhisper   // OpenAI Whisper API (whisper-1).
    case assemblyAI      // AssemblyAI /v2/transcript API.

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .whisperKit:    return "WhisperKit (on-device)"
        case .openAIWhisper: return "OpenAI Whisper"
        case .assemblyAI:    return "AssemblyAI"
        }
    }

    /// Short tagline shown under the picker.
    var tagline: String {
        switch self {
        case .whisperKit:    return "Runs offline. No speaker labels."
        case .openAIWhisper: return "Cloud. 25 MB cap. No speaker labels."
        case .assemblyAI:    return "Cloud. Speaker labels supported."
        }
    }

    struct Capabilities {
        let supportsTranslationToEnglish: Bool
        let supportsSpeakerDiarization: Bool
        let requiresAPIKey: Bool
    }

    var capabilities: Capabilities {
        switch self {
        case .whisperKit:
            return .init(supportsTranslationToEnglish: true,
                         supportsSpeakerDiarization: false,
                         requiresAPIKey: false)
        case .openAIWhisper:
            return .init(supportsTranslationToEnglish: true,
                         supportsSpeakerDiarization: false,
                         requiresAPIKey: true)
        case .assemblyAI:
            // AssemblyAI's v2/transcript doesn't translate inline — you'd
            // need a separate LeMUR call. Treat translation as unsupported
            // for now; UI grays it out when this backend is selected.
            return .init(supportsTranslationToEnglish: false,
                         supportsSpeakerDiarization: true,
                         requiresAPIKey: true)
        }
    }
}
