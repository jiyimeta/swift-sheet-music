import Foundation
@_exported import SheetMusicCore
@_exported import SheetMusicMIDI
@_exported import SheetMusicMSCX

/// Top-level convenience façade for the SheetMusic family of libraries.
///
/// `import SheetMusic` re-exports `SheetMusicCore`, `SheetMusicMSCX`, and
/// `SheetMusicMIDI` so all public types of the typical "load mscx → export
/// MIDI" pipeline are visible without per-library imports. Future format
/// libraries (e.g. PDF, MusicXML) and the `SheetMusicUI` /
/// `SheetMusicPlayback` libraries can be re-exported here as they're added.
public enum SheetMusic {
    /// Parse uncompressed `.mscx` data into a `Score`.
    public static func loadScore(mscxData: Data) throws -> Score {
        try MSCXParser.parse(mscxData)
    }

    /// Render a `Score` to SMF (Standard MIDI File) bytes.
    public static func exportMIDI(score: Score) throws -> Data {
        let midiFile = try MidiRenderer.render(score: score)
        return try MidiWriter.write(midiFile)
    }
}
