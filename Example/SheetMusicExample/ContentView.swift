#if !os(macOS)
import SheetMusic
import SheetMusicUI
import SwiftUI

struct ContentView: View {
    @State private var score: Score?
    @State private var errorMessage: String?
    @State private var verticalLayout = true

    var body: some View {
        NavigationStack {
            Group {
                if let score {
                    scoreContent(score: score)
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Picker("Layout", selection: $verticalLayout) {
                        Image(systemName: "arrow.up.and.down")
                            .tag(true)
                        Image(systemName: "arrow.left.and.right")
                            .tag(false)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 100)
                }
            }
        }
        .onAppear(perform: loadBundled)
    }

    @ViewBuilder
    private func scoreContent(score: Score) -> some View {
        let opts = ScoreViewOptions(
            staffSize: 20,
            systemGap: 30,
            wrapToViewWidth: verticalLayout)
        if verticalLayout {
            ScrollView(.vertical) {
                ScoreView(score: score, options: opts)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 16)
            }
        } else {
            ScrollView(.horizontal) {
                ScoreView(score: score, options: opts)
                    .padding(16)
            }
        }
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
