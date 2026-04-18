#if os(macOS)
import SheetMusic
import SheetMusicUI
import SwiftUI

@available(macOS 15.0, *)
struct ContentViewMac: View {
    @State private var score: Score?
    @State private var sourceName = "(none)"
    @State private var errorMessage: String?
    @State private var magnification: CGFloat = 1.0
    @State private var steadyMagnification: CGFloat = 1.0
    @State private var zoomAnchor: UnitPoint = .center
    @State private var verticalLayout = false

    var body: some View {
        NavigationSplitView {
            List {
                Section("Bundled") {
                    Button("Load test.mscx") {
                        loadBundled()
                    }
                }
                Section("Layout") {
                    Picker("Scroll", selection: $verticalLayout) {
                        Label("Horizontal", systemImage: "arrow.left.and.right")
                            .tag(false)
                        Label("Vertical", systemImage: "arrow.up.and.down")
                            .tag(true)
                    }
                    .pickerStyle(.inline)
                }
                Section("Zoom") {
                    Text("\(Int(steadyMagnification * 100))%")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Reset (100%)") {
                        steadyMagnification = 1.0
                        magnification = 1.0
                    }
                    .disabled(steadyMagnification == 1.0)
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
                scoreContent(score: score)
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

    @ViewBuilder
    private func scoreContent(score: Score) -> some View {
        let opts = ScoreViewOptions(
            staffSize: verticalLayout ? 18 : 28,
            systemGap: verticalLayout ? 16 : 40,
            wrapToViewWidth: verticalLayout)
        if verticalLayout {
            ScrollView(.vertical) {
                ScoreView(score: score, options: opts)
                    .padding()
            }
        } else {
            ScrollView([.vertical, .horizontal]) {
                ScoreView(score: score, options: opts)
                    .scaleEffect(magnification, anchor: zoomAnchor)
                    .padding()
                    .simultaneousGesture(
                        MagnifyGesture()
                            .onChanged { value in
                                zoomAnchor = value.startAnchor
                                magnification = steadyMagnification
                                    * value.magnification
                            }
                            .onEnded { value in
                                steadyMagnification *=
                                    value.magnification
                                steadyMagnification = min(
                                    max(steadyMagnification, 0.25),
                                    4.0)
                                magnification = steadyMagnification
                            }
                    )
            }
        }
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
