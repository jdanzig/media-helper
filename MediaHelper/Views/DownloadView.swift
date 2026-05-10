import SwiftUI

/// UI for the Download tab. Thin: it binds to `DownloadViewModel` and
/// reacts to published state changes. All business logic lives in the
/// view model.
struct DownloadView: View {
    @StateObject private var vm = DownloadViewModel()
    @FocusState private var urlFieldFocused: Bool
    @State private var shareItems: [URL] = []
    @State private var isSharePresented = false
    @Environment(\.scenePhase) private var scenePhase

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
                                vm.clearURL()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Clear URL")
                        }
                    }

                    platformRow

                    if let suggestion = vm.clipboardSuggestion {
                        clipboardSuggestionRow(suggestion)
                    }
                }

                TranscriptionOptionsView(
                    selections: $vm.selections,
                    backend: $vm.backend,
                    speakerLabels: $vm.speakerLabels
                )

                Section("Status") {
                    statusBanner
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
                        if vm.resolvedCount > 1 {
                            LabeledContent("Items", value: "\(vm.resolvedCount)")
                        } else {
                            LabeledContent("Type", value: r.isVideo ? "Video" : "Image")
                        }
                        LabeledContent("Host", value: r.mediaURL.host ?? "—")
                    }
                }

                Section {
                    Button {
                        urlFieldFocused = false
                        Task { await vm.start() }
                    } label: {
                        HStack {
                            if isWorking {
                                ProgressView()
                                    .controlSize(.small)
                                    .padding(.trailing, 6)
                            } else {
                                Image(systemName: "arrow.down.circle.fill")
                            }
                            Text(isWorking ? "Working…" : "Download")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(!canStart || isWorking)

                    if case .done = vm.phase, let fileURL = vm.downloadedFileURL {
                        Button {
                            shareItems = [fileURL]
                            isSharePresented = true
                        } label: {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }

                    if case .done = vm.phase, let outputs = vm.outputs {
                        outputsView(outputs)
                    }

                    Button("Clear", role: .destructive) { vm.reset() }
                        .disabled(vm.urlText.isEmpty)
                }
            }
            .navigationTitle("Download")
            .scrollDismissesKeyboard(.immediately)
            .onAppear { vm.checkClipboard() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { vm.checkClipboard() }
            }
            // Note: an `.onTapGesture` at this level was intercepting
            // some Button taps inside the Form (Buttons inside a Form
            // section don't reliably claim taps over a parent gesture),
            // so we rely on `scrollDismissesKeyboard` plus the keyboard
            // toolbar's Done button to dismiss the keyboard.
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

    @ViewBuilder
    private func clipboardSuggestionRow(_ suggestion: (url: String, platform: SocialPlatform)) -> some View {
        HStack(spacing: 10) {
            Image(systemName: suggestion.platform.symbol)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Link copied from \(suggestion.platform.displayName)")
                    .font(.subheadline)
                Text(suggestion.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                vm.acceptClipboardSuggestion()
            } label: {
                Text("Paste")
                    .font(.subheadline.bold())
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.small)

            Button {
                vm.dismissClipboardSuggestion()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss suggestion")
        }
        .padding(.vertical, 4)
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
        case .resolving, .downloading, .postProcessing, .done: return false
        default: return vm.detectedPlatform != .unknown
        }
    }

    private var showsProgressBar: Bool {
        switch vm.phase {
        case .downloading, .postProcessing: return true
        default: return false
        }
    }

    /// True while a download/transcribe is actively running. Drives the
    /// inline spinner on the Download button so the user has an
    /// unmistakable signal that work is happening.
    private var isWorking: Bool {
        switch vm.phase {
        case .resolving, .downloading, .postProcessing: return true
        default: return false
        }
    }

    /// More visually obvious status row than plain footnote text: pairs
    /// the message with an SF Symbol that reflects the current phase.
    @ViewBuilder
    private var statusBanner: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            switch vm.phase {
            case .idle, .detecting:
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
            case .resolving, .downloading, .postProcessing:
                ProgressView().controlSize(.small)
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Text(vm.statusMessage)
                .font(.footnote)
                .foregroundStyle(isWorking ? Color.primary : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#Preview { DownloadView() }
