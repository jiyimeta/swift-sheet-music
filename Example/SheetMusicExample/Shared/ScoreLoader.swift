import Foundation
import SheetMusic
import SheetMusicAudio

/// Cross-platform helpers for opening score files. Both the iOS
/// document picker (`.fileImporter`) and macOS `NSOpenPanel`
/// hand us a security-scoped URL whose contents must be read
/// inside `startAccessingSecurityScopedResource()`; this helper
/// centralises that bookkeeping along with the format switch
/// over `ScoreFileType`.
enum ScoreLoader {
    /// Read the bundled `test.mscx` shipped with the example. The
    /// file is registered as a resource by the Xcode target — if
    /// it goes missing the build is broken, so we raise a clear
    /// error instead of silently leaving the UI empty.
    static func loadBundled() throws -> Score {
        guard let url = Bundle.main.url(
            forResource: "test", withExtension: "mscx"
        )
        else {
            throw LoadError.bundledMissing
        }
        let data = try Data(contentsOf: url)
        return try SheetMusic.loadScore(mscxData: data)
    }

    /// Load a user-picked score. Wraps the security-scoped resource
    /// dance and dispatches to the format-specific loader based on
    /// `ScoreFileType.detect(url:)`.
    static func load(from url: URL) throws -> Score {
        let started = url.startAccessingSecurityScopedResource()
        defer {
            if started {
                url.stopAccessingSecurityScopedResource()
            }
        }
        switch ScoreFileType.detect(url: url) {
        case .mscx:
            return try SheetMusic.loadScore(mscxURL: url)
        case .mscz:
            return try SheetMusic.loadScore(msczURL: url)
        case .musicXML:
            let data = try Data(contentsOf: url)
            return try SheetMusic.loadScore(musicXMLData: data)
        case .mxl:
            let data = try Data(contentsOf: url)
            return try SheetMusic.loadScore(mxlData: data)
        case nil:
            throw LoadError.unsupported(filename: url.lastPathComponent)
        }
    }

    enum LoadError: LocalizedError {
        case bundledMissing
        case unsupported(filename: String)

        var errorDescription: String? {
            switch self {
            case .bundledMissing:
                return "Bundled test.mscx not found."
            case let .unsupported(name):
                return "Unsupported file: \(name)"
            }
        }
    }
}

extension PlaybackEngine {
    /// Off-main sampler prep. SoundFont parsing can take tens of ms
    /// per file; deferring via `Task` keeps the current view body
    /// responsive while the sampler set rebuilds. Errors are
    /// intentionally swallowed — sampler init failure leaves the
    /// engine silent rather than blocking score rendering.
    ///
    /// `prepare(score:)` is `@MainActor`-isolated, so the work
    /// itself still runs on main; the surrounding `Task` only
    /// guarantees we yield back to SwiftUI before doing it.
    func prepareInBackground(score: Score) {
        Task { [self] in
            try? prepare(score: score)
        }
    }
}
