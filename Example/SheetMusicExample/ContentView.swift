#if !os(macOS)
import SheetMusic
import SheetMusicUI
import SwiftUI

struct ContentView: View {
    @State private var score: Score?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if let score {
                    ScrollView(.vertical) {
                        ScoreView(
                            score: score,
                            options: ScoreViewOptions(
                                staffSize: 20,
                                systemGap: 30,
                                wrapToViewWidth: true))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 16)
                    }
                } else if let error = errorMessage {
                    VStack {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView("Loading…")
                }
            }
            .navigationTitle("Sheet Music")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear(perform: loadBundled)
    }

    private func loadBundled() {
        guard let url = Bundle.main.url(
            forResource: "test", withExtension: "mscx")
        else {
            errorMessage = "Bundled test.mscx not found."
            return
        }
        do {
            let data = try Data(contentsOf: url)
            score = try SheetMusic.loadScore(mscxData: data)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
#endif
