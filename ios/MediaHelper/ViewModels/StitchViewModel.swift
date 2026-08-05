import SwiftUI
import PhotosUI

/// Owns the state for the Stitch tab: the chosen PhotosPicker items, the
/// `UIImage`s loaded from them, the stitch axis, and the rendered output.
@MainActor
final class StitchViewModel: ObservableObject {

    @Published var pickerItems: [PhotosPickerItem] = [] {
        didSet {
            guard !suppressPickerReload else { return }
            Task { await loadImages() }
        }
    }
    /// Set to true when removeImage mutates pickerItems directly so the
    /// didSet observer skips the expensive full reload.
    private var suppressPickerReload = false
    @Published private(set) var images: [UIImage] = []
    /// Stable per-image UUIDs that survive reordering, giving SwiftUI's
    /// ForEach a consistent identity so thumbnails animate as moves, not
    /// insert/delete pairs.
    @Published private(set) var imageIDs: [UUID] = []
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
        images   = loaded
        imageIDs = loaded.map { _ in UUID() }
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

    /// Remove a single image by index without re-fetching the remaining ones.
    /// Also removes the corresponding PhotosPickerItem so the picker reflects
    /// the current selection next time it opens.
    func removeImage(at index: Int) {
        guard images.indices.contains(index) else { return }
        suppressPickerReload = true
        pickerItems.remove(at: index)
        suppressPickerReload = false
        images.remove(at: index)
        imageIDs.remove(at: index)
        if images.isEmpty {
            output = nil
            status = "Pick images to stitch."
        } else {
            render()
        }
    }

    /// Move a thumbnail from one position to another (drag-to-reorder).
    /// Called by the drop delegate in StitchView.
    func moveImage(from source: IndexSet, to destination: Int) {
        images.move(fromOffsets: source, toOffset: destination)
        imageIDs.move(fromOffsets: source, toOffset: destination)
        render()
    }

    /// Reset to the initial empty state.
    func clear() {
        pickerItems = []   // triggers loadImages() → resets images, output & status
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
