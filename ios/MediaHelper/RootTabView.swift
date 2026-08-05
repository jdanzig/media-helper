import SwiftUI

struct RootTabView: View {
    var body: some View {
        TabView {
            DownloadView()
                .tabItem { Label("Download", systemImage: "arrow.down.circle") }

            TranscribeView()
                .tabItem { Label("Transcribe", systemImage: "captions.bubble") }

            StitchView()
                .tabItem { Label("Stitch", systemImage: "rectangle.split.2x1") }

            SquarifyView()
                .tabItem { Label("Squarify", systemImage: "square.dashed") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

#Preview {
    RootTabView()
}
