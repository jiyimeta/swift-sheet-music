import Foundation
import SheetMusicAudioCore
import SheetMusicCore
import SheetMusicLoader
import Testing

/// What the export tests load and resolve with.
enum Fixtures {
    /// A `SheetMusicTests` fixture, read where it is rather than copied: `repeat52.mscx` is one of MuseScore's, under
    /// the terms that folder's `LICENSE` records.
    static func url(_ name: String) throws -> URL {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SheetMusicTests/Resources/\(name).mscx")
        try #require(FileManager.default.fileExists(atPath: url.path), "no fixture at \(url.path)")
        return url
    }

    static func score(_ name: String) throws -> Score {
        try ScoreLoader.loadScore(contentsOf: url(name))
    }

    /// No SoundFont: every synth renders silence, which is all a length or a container needs.
    static let silentResolver = NoSoundFont()

    struct NoSoundFont: SoundfontResolver {
        func soundfontURL(forBank _: UInt8, program _: UInt8, isDrums _: Bool) -> URL? {
            nil
        }

        var defaultGMSoundfontURL: URL? {
            nil
        }
    }

    /// A fresh file name in the temporary folder.
    static func temporaryFile(_ fileExtension: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ssm-export-\(UUID().uuidString).\(fileExtension)")
    }
}
