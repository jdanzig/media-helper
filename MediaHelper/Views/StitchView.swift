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

                Toggle("Divider line between images", isOn: $vm.showDivider)
                    .padding(.horizontal)

                // Preview fills remaining vertical space. ZoomableImageView
                // starts at aspect-fit scale; pinch to zoom, one finger to pan.
                Group {
                    if let out = vm.output {
                        ZoomableImageView(image: out)
                    } else {
                        ContentUnavailableView(
                            "No preview",
                            systemImage: "rectangle.on.rectangle",
                            description: Text("Pick two or more images to see a preview.")
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)

                Text(vm.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button("Clear", role: .destructive) {
                        vm.clear()
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                    .disabled(vm.images.isEmpty)

                    Button {
                        Task { await vm.save() }
                    } label: {
                        if vm.isSaving { ProgressView() }
                        else { Label("Save to Photos", systemImage: "square.and.arrow.down") }
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .disabled(vm.output == nil || vm.isSaving)
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Stitch")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

#Preview { StitchView() }
