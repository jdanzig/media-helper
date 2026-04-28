import SwiftUI

/// UI for the Download tab. Thin: it binds to `DownloadViewModel` and
/// reacts to published state changes. All business logic lives in the
/// view model.
struct DownloadView: View {
    @StateObject private var vm = DownloadViewModel()
    @FocusState private var urlFieldFocused: Bool
    @State private var shareItems: [URL] = []
    @State private var isSharePresented = false

    var body: some View {
        NavigationStack {
            Form {
                Section("URL") {
                    HStack(spacing: 8) {
                        TextField("Paste a YouTube / X / TikTok / Instagram / Facebook link",
                                  text: $vm.urlText, axis: .vertical)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .focused($urlFieldFocused)
                            .onChange(of: vm.urlText) { _, _ in vm.urlDidChange() }

                        if !vm.urlText.isEmpty {
                            Button {
                                vm.urlText = ""
                                vm.urlDidChange()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Clear URL")
                        }
                    }

                    // PasteButton triggers the system clipboard read
                    // without showing iOS's "wants to paste" alert,
                    // because user tapped the button explicitly.
                    PasteButton(payloadType: String.self) { strings in
                        guard let s = strings.first else { return }
                        Task { @MainActor in
                            vm.urlText = s.trimmingCharacters(in: .whitespacesAndNewlines)
                            vm.urlDidChange()
                        }
                    }
                    .labelStyle(.titleAndIcon)
                    .buttonBorderShape(.capsule)

                    platformRow
                }

                TranscriptionOptionsView(
                    preset: $vm.preset,
                    backend: $vm.backend,
                    speakerLabels: $vm.speakerLabels
                )

                Section("Status") {
                    Text(vm.statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if showsProgressBar {
                        ProgressView(value: vm.progress)
                        Text("\(Int(vm.progress * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                if let r = vm.resolved {
                    Section("Resolved") {
                        if let t = r.title {
                            LabeledContent("Title", value: t).lineLimit(3)
                        }
                        LabeledContent("Type", value: r.isVideo ? "Video" : "Image")
                        LabeledContent("Host", value: r.mediaURL.host ?? "—")
                    }
                }

                Section {
                    Button {
                        urlFieldFocused = false
                        Task { await vm.start() }
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(!canStart)

                    if case .done = vm.phase, let outputs = vm.outputs {
                        outputsView(outputs)
                    }

                    Button("Clear", role: .destructive) { vm.reset() }
                        .disabled(vm.urlText.isEmpty)
                }
            }
            .navigationTitle("Download")
            .scrollDismissesKeyboard(.immediately)
            // Tap on any inert spot in the form (between cells / on a
            // section header) drops focus. Interactive cells like the
            // TextField and Buttons intercept first, which is what we
            // want — this only fires on the "empty" parts of the form.
            .onTapGesture { urlFieldFocused = false }
            .toolbar {
                // Tap-anywhere-to-dismiss isn't quite a thing in Form,
                // so a Done button on the keyboard accessory bar gives
                // the user a clear way to put the keyboard down.
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { urlFieldFocused = false }
                }
            }
            .sheet(isPresented: $isSharePresented) {
                ShareSheet(items: shareItems)
            }
        }
    }

    private var platformRow: some View {
        HStack {
            Image(systemName: vm.detectedPlatform.symbol)
                .foregroundStyle(.tint)
            Text(vm.detectedPlatform.displayName)
                .font(.subheadline)
            Spacer()
            if case .downloading = vm.phase    { ProgressView().controlSize(.small) }
            if case .resolving = vm.phase      { ProgressView().controlSize(.small) }
            if case .postProcessing = vm.phase { ProgressView().controlSize(.small) }
            if case .done = vm.phase {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            if case .failed = vm.phase {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private func outputsView(_ o: TranscriptionOutputs) -> some View {
        if o.subtitledVideoURL != nil {
            Label("Saved subtitled video to Photos", systemImage: "captions.bubble.fill")
                .font(.footnote)
        }
        if let srt = o.subtitleFileURL {
            Button {
                shareItems = [srt]
                isSharePresented = true
            } label: {
                Label("Share .srt file", systemImage: "square.and.arrow.up")
            }
        }
        if let txt = o.transcriptFileURL {
            Button {
                shareItems = [txt]
                isSharePresented = true
            } label: {
                Label("Share transcript (.txt)", systemImage: "square.and.arrow.up")
            }
        }
    }

    private var canStart: Bool {
        guard !vm.urlText.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch vm.phase {
        case .resolving, .downloading, .postProcessing: return false
        default: return vm.detectedPlatform != .unknown
        }
    }

    private var showsProgressBar: Bool {
        switch vm.phase {
        case .downloading, .postProcessing: return true
        default: return false
        }
    }
}

#Preview { DownloadView() }
