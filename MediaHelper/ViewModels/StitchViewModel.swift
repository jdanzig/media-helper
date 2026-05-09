import SwiftUI
import PhotosUI

/// Owns the state for the Stitch tab: the chosen PhotosPicker items, the
/// `UIImage`s loaded from them, the stitch axis, and the rendered output.
@MainActor
final class StitchViewModel: ObservableObject {

    @Published var pickerItems: [PhotosPickerItem] = [] {
        didSet { Task { await loadImages() } }
    }
    @Published private(set) var images: [UIImage] = []
    @Published var axis: StitchAxis = .vertical {
        didSet { render() }
    }
    @Published var showDivider: Bool = false {
        didSet { render() }
    }
    @Published private(set) var output: UIImage?
    @Published private(set) var status: String = "Pick images to stitch."
    @Published var isSaving = false

    /// Read `UIImage`s out of the PhotosPicker selection in parallel.
    /// PhotosPickerItem ids preserve selection order, so the stitch order
    /// is stable and user-controllable.
    private func loadImages() async {
        guard !pickerItems.isEmpty else {
            images = []; output = nil
            status = "Pick images to stitch."
            return
        }
        status = "Loading \(pickerItems.count) images…"

        var loaded: [UIImage] = []
        for item in pickerItems {
            if let data = try? await item.loadTransferable(type: Data.self),
               let img = UIImage(data: data) {
                loaded.append(img)
            }
        }
        images = loaded
        render()
    }

    private func render() {
        guard !images.isEmpty else { output = nil; return }
        status = "Rendering…"
        Task.detached(priority: .userInitiated) { [images, axis, showDivider] in
            let out = ImageStitcher.stitch(images, axis: axis, divider: showDivider)
            await MainActor.run {
                self.output = out
                self.status = out == nil
                    ? "Couldn't render — check image sizes."
                    : "\(images.count) images • \(axis.label)."
            }
        }
    }

    func save() async {
        guard let output else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await PhotoLibrarySaver.saveImage(output)
            status = "Saved to Photos."
        } catch {
            status = error.localizedDescription
        }
    }
}
