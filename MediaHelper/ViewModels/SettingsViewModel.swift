import Foundation
import SwiftUI

/// Settings tab state: which API keys are configured and the typed
/// values while the user is editing. Values are flushed to the keychain
/// only when the user hits "Save" on a given field.
@MainActor
final class SettingsViewModel: ObservableObject {

    @Published var openAIKeyInput: String = ""
    @Published var assemblyAIKeyInput: String = ""

    @Published private(set) var hasOpenAIKey: Bool = false
    @Published private(set) var hasAssemblyAIKey: Bool = false

    init() { reload() }

    /// Re-read presence of each key from the keychain. Call when returning
    /// to this view in case something changed elsewhere.
    func reload() {
        hasOpenAIKey = KeychainStore.hasValue(for: .openAIAPIKey)
        hasAssemblyAIKey = KeychainStore.hasValue(for: .assemblyAIAPIKey)
        openAIKeyInput = ""
        assemblyAIKeyInput = ""
    }

    func saveOpenAIKey() {
        let trimmed = openAIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? KeychainStore.save(trimmed, for: .openAIAPIKey)
        hasOpenAIKey = true
        openAIKeyInput = ""
    }

    func clearOpenAIKey() {
        KeychainStore.delete(.openAIAPIKey)
        hasOpenAIKey = false
    }

    func saveAssemblyAIKey() {
        let trimmed = assemblyAIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? KeychainStore.save(trimmed, for: .assemblyAIAPIKey)
        hasAssemblyAIKey = true
        assemblyAIKeyInput = ""
    }

    func clearAssemblyAIKey() {
        KeychainStore.delete(.assemblyAIAPIKey)
        hasAssemblyAIKey = false
    }
}
