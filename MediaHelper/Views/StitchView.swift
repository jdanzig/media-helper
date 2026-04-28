import SwiftUI
import PhotosUI

/// UI for the Stitch tab. The picker lets the user select multiple images;
/// a segmented control chooses vertical vs horizontal layout; the preview
/// shows the composite output; a Save button writes it to Photos.
@MainActor
struct StitchView: View {
    @StateObject private var vm = StitchViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {

                PhotosPicker(
                    selection: $vm.pickerItems,
                    maxSelectionCount: 20,
                    selectionBehavior: .ordered,
                    matching: .images
                ) {
                    Label(
                        vm.images.isEmpty ? "Pick images" : "Change selection (\(vm.images.count))",
                        systemImage: "photo.on.rectangle.angled"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)

                Picker("Axis", selection: $vm.axis) {
                    ForEach(StitchAxis.allCases) { axis in
                        Text(axis.label).tag(axis)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                // Preview: scrollable so tall vertical stitches aren't clipped.
                ScrollView([.vertical, .horizontal]) {
                    if let out = vm.output {
                        Image(uiImage: out)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .padding()
                    } else {
                        ContentUnavailableView(
                            "No preview",
                            systemImage: "rectangle.on.rectangle",
                            description: Text("Pick two or more images to see a preview.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 200)
                    }
                }
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)

                Text(vm.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button {
                    Task { await vm.save() }
                } label: {
                    if vm.isSaving { ProgressView() }
                    else { Label("Save to Photos", systemImage: "square.and.arrow.down") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.output == nil || vm.isSaving)
                .padding(.horizontal)
                .padding(.bottom)
            }
            .navigationTitle("Stitch")
            // Same drift issue as SquarifyView: nested ScrollView in a
            // VStack root makes the large title untether from the bar
            // when the user drags. Inline mode pins it.
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

#Preview { StitchView() }
