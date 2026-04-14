import SheetMusic
import SwiftUI

struct ContentView: View {
    @State private var statusMessage = "Loading bundled test.mscx…"
    @State private var generatedMIDIURL: URL?
    @State private var scoreSummary: String?

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "music.note")
                .font(.system(size: 64))
                .foregroundStyle(.tint)

            Text(statusMessage)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            if let summary = scoreSummary {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            if let url = generatedMIDIURL {
                ShareLink(item: url) {
                    Label("Share MIDI File", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .onOpenURL(perform: handleMSCX)
        .onAppear {
            if let bundled = Bundle.main.url(forResource: "test", withExtension: "mscx") {
                handleMSCX(url: bundled)
            } else {
                statusMessage = "No bundled test.mscx found."
            }
        }
    }

    private func handleMSCX(url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let score = try SheetMusic.loadScore(mscxData: data)
            let midiData = try SheetMusic.exportMIDI(score: score)

            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(url.deletingPathExtension().lastPathComponent)
                .appendingPathExtension("mid")
            try midiData.write(to: outputURL)

            generatedMIDIURL = outputURL
            scoreSummary = """
            \(score.parts.count) part\(score.parts.count == 1 ? "" : "s") · \
            \(score.staves.count) staff/staves · \
            division \(score.division) PPQ
            MIDI: \(midiData.count) bytes
            """
            statusMessage = "Converted \(url.lastPathComponent)"
        } catch {
            generatedMIDIURL = nil
            scoreSummary = nil
            statusMessage = "Conversion failed: \(error.localizedDescription)"
        }
    }
}

#Preview {
    ContentView()
}
