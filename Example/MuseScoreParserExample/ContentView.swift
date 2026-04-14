import MuseScoreParser
import SwiftUI

struct ContentView: View {
    @State private var statusMessage = "Waiting for .mscx file…"
    @State private var generatedMIDIURL: URL?

    var body: some View {
        VStack(spacing: 20) {
            Text(statusMessage)
            
            if let url = generatedMIDIURL {
                ShareLink(item: url) {
                    Label("Share MIDI File", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .onOpenURL { url in
            handleMSCX(url: url)
        }
        .onAppear {
            let url = Bundle.main.url(forResource: "test", withExtension: "mscx")!
            handleMSCX(url: url)
        }
    }

    private func handleMSCX(url: URL) {
        do {
            let museScoreFile = try MuseScoreFile(mscxFileURL: url)

            print("$$$ \(Self.self).\(#function)", museScoreFile.score)

            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(url.deletingPathExtension().lastPathComponent)
                .appendingPathExtension("mid")

            try museScoreFile.exportMIDI(to: outputURL)

            generatedMIDIURL = outputURL
            statusMessage = "MIDI saved to \(outputURL.lastPathComponent)"
        } catch {
            statusMessage = "MIDI write failed: \(error.localizedDescription)"
            print("Error:", error)
            generatedMIDIURL = nil
        }
    }
}

#Preview {
    ContentView()
}
