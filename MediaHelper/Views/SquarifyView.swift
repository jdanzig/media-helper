import SwiftUI
import PhotosUI

/// UI for the Squarify tab. One image in, one square image out, with
/// padding filled by the top-left pixel color of the source.
@MainActor
struct SquarifyView: View {
    @StateObject private var vm = SquarifyViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {

                PhotosPicker(
                    selection: $vm.pickerItem,
                    matching: .images
                ) {
                    Label(
                        vm.source == nil ? "Pick image" : "Change image",
                        systemImage: "photo"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)

                ScrollView {
                    if let out = vm.output {
                        Image(uiImage: out)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .padding()
                    } else {
                        ContentUnavailableView(
                            "No preview",
                            systemImage: "square.dashed",
                            description: Text("Pick a rectangular image to see the squared result.")
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
            .navigationTitle("Squarify")
            // Lock the title to the nav bar. With a `VStack` root and a
            // nested ScrollView, the large-title transition can drift —
            // dragging inside the scroll view pulls the large title down
            // and out of position. Inline mode pins it.
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

#Preview { SquarifyView() }
