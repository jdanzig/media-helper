import SwiftUI

/// Settings tab. Right now it just owns API-key entry for the two cloud
/// transcription backends. Each field shows "Connected" once a value has
/// been saved to the keychain, and offers a Remove button.
struct SettingsView: View {
    @StateObject private var vm = SettingsViewModel()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Add your API keys to unlock the cloud transcription backends. Keys are stored in the iOS keychain on this device only.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                keySection(title: "OpenAI Whisper",
                           tagline: "Powers the “OpenAI Whisper” transcription backend.",
                           hasKey: vm.hasOpenAIKey,
                           input: $vm.openAIKeyInput,
                           onSave: vm.saveOpenAIKey,
                           onClear: vm.clearOpenAIKey)

                keySection(title: "AssemblyAI",
                           tagline: "Required for the “AssemblyAI” backend (includes speaker labels).",
                           hasKey: vm.hasAssemblyAIKey,
                           input: $vm.assemblyAIKeyInput,
                           onSave: vm.saveAssemblyAIKey,
                           onClear: vm.clearAssemblyAIKey)

                cookieSection(title: "Instagram",
                              tagline: "Some posts are restricted to logged-in users. Paste your sessionid cookie here to unlock them. Get it from Instagram.com → DevTools → Application → Cookies.",
                              hasCookie: vm.hasInstagramCookie,
                              input: $vm.instagramCookieInput,
                              onSave: vm.saveInstagramCookie,
                              onClear: vm.clearInstagramCookie)

                cookieSection(title: "TikTok",
                              tagline: "Age-restricted posts need a login. Paste your sessionid cookie to unlock them. Get it from TikTok.com → DevTools → Application → Cookies.",
                              hasCookie: vm.hasTikTokCookie,
                              input: $vm.tiktokCookieInput,
                              onSave: vm.saveTikTokCookie,
                              onClear: vm.clearTikTokCookie)
            }
            .navigationTitle("Settings")
            .onAppear { vm.reload() }
        }
    }

    @ViewBuilder
    private func keySection(title: String,
                            tagline: String,
                            hasKey: Bool,
                            input: Binding<String>,
                            onSave: @escaping () -> Void,
                            onClear: @escaping () -> Void) -> some View {
        Section(header: Text(title)) {
            Text(tagline)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if hasKey {
                HStack {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text("Connected")
                    Spacer()
                    Button("Remove", role: .destructive, action: onClear)
                        .buttonStyle(.borderless)
                }
            }

            SecureField(hasKey ? "Replace key (optional)" : "API key", text: input)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Button {
                onSave()
            } label: {
                Label(hasKey ? "Replace" : "Save", systemImage: "square.and.arrow.down")
            }
            .disabled(input.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    /// Like `keySection` but for a pasted session cookie: plain TextField
    /// (so the user can verify the value) and cookie-flavoured copy.
    @ViewBuilder
    private func cookieSection(title: String,
                               tagline: String,
                               hasCookie: Bool,
                               input: Binding<String>,
                               onSave: @escaping () -> Void,
                               onClear: @escaping () -> Void) -> some View {
        Section(header: Text(title)) {
            Text(tagline)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if hasCookie {
                HStack {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text("Cookie saved")
                    Spacer()
                    Button("Remove", role: .destructive, action: onClear)
                        .buttonStyle(.borderless)
                }
            }

            TextField(hasCookie ? "Replace sessionid (optional)" : "sessionid value", text: input)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Button {
                onSave()
            } label: {
                Label(hasCookie ? "Replace" : "Save", systemImage: "square.and.arrow.down")
            }
            .disabled(input.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}

#Preview { SettingsView() }
