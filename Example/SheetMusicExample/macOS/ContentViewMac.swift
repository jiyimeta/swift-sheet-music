#if os(macOS)
import SheetMusic
import SheetMusicUI
import SwiftUI

@available(macOS 15.0, *)
struct ContentViewMac: View {
    @State private var score: Score?
    @State private var sourceName = "(none)"
    @State private var errorMessage: String?

    var body: some View {
        NavigationSplitView {
            List {
                Section("Bundled") {
                    Button("Load test.mscx") {
                        loadBundled()
                    }
                }
                Section("State") {
                    Text(sourceName)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let message = errorMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 240)
        } detail: {
            if let score {
                ScrollView([.vertical, .horizontal]) {
                    ScoreView(score: score)
                        .padding()
                }
            } else {
                ContentUnavailableView(
                    "No score loaded",
                    systemImage: "music.note.list",
                    description: Text(
                        "Load the bundled test.mscx from the sidebar."))
            }
        }
        .onAppear(perform: loadBundled)
    }

    private func loadBundled() {
        guard
            let url = Bundle.main.url(
                forResource: "test", withExtension: "mscx")
        else {
            errorMessage = "Bundled test.mscx not found."
            return
        }
        do {
            let data = try Data(contentsOf: url)
            score = try SheetMusic.loadScore(mscxData: data)
            sourceName = url.lastPathComponent
            errorMessage = nil
        } catch {
            errorMessage = "Failed: \(error.localizedDescription)"
        }
    }
}
#endif
