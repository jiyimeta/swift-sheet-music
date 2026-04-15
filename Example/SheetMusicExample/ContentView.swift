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
        .onOpenURL(perform: handleScore)
        .onAppear {
            if let bundled = Bundle.main.url(forResource: "test", withExtension: "mscx") {
                handleScore(url: bundled)
            } else {
                statusMessage = "No bundled test.mscx found."
            }
        }
    }

    /// Decide which loader to use based on the file extension, then convert
    /// to a `Score` and export MIDI. Supports `.mscx`, `.mscz`, `.musicxml`,
    /// `.xml` (treated as MusicXML), and `.mxl` (compressed MusicXML).
    private func handleScore(url: URL) {
        // iOS hands us a security-scoped URL when the file lives outside our
        // sandbox (e.g. a Files.app pick). We must release the access when done.
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer { if didStartAccess { url.stopAccessingSecurityScopedResource() } }

        do {
            let data = try Data(contentsOf: url)
            let ext = url.pathExtension.lowercased()
            let score: Score
            switch ext {
            case "mscx":
                score = try SheetMusic.loadScore(mscxData: data)
            case "mscz":
                score = try SheetMusic.loadScore(msczData: data)
            case "musicxml", "xml":
                score = try SheetMusic.loadScore(musicXMLData: data)
            case "mxl":
                score = try SheetMusic.loadScore(mxlData: data)
            default:
                statusMessage = "Unsupported file type: .\(ext)"
                generatedMIDIURL = nil
                scoreSummary = nil
                return
            }
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
