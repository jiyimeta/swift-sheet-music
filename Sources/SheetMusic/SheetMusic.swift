import Foundation
@_exported import SheetMusicCore
@_exported import SheetMusicMIDI
@_exported import SheetMusicMSCX

/// Top-level convenience façade for the SheetMusic family of libraries.
///
/// `import SheetMusic` re-exports `SheetMusicCore`, `SheetMusicMSCX`, and
/// `SheetMusicMIDI` so all public types of the typical "load mscx/mscz →
/// export MIDI" pipeline are visible without per-library imports.
public enum SheetMusic {
    /// Parse uncompressed `.mscx` bytes into a `Score`.
    public static func loadScore(mscxData: Data) throws -> Score {
        try MSCXParser.parse(mscxData)
    }

    /// Parse `.mscz` container bytes into a `Score` (main `.mscx` only).
    public static func loadScore(msczData: Data) throws -> Score {
        try MSCZReader.parse(msczData)
    }

    /// Read an `.mscx` file and parse into a `Score`.
    public static func loadScore(mscxURL: URL) throws -> Score {
        try MSCXParser.parse(contentsOf: mscxURL)
    }

    /// Read an `.mscz` file and parse its main `.mscx` into a `Score`.
    public static func loadScore(msczURL: URL) throws -> Score {
        try MSCZReader.parse(contentsOf: msczURL)
    }

    /// Package caller-supplied `.mscx` XML bytes into `.mscz` bytes.
    public static func saveMSCZ(mscxData: Data) throws -> Data {
        try MSCZWriter.write(mscxData: mscxData)
    }

    /// Package `.mscx` bytes and write the resulting `.mscz` to a file URL.
    public static func saveMSCZ(mscxData: Data, to url: URL) throws {
        try MSCZWriter.write(mscxData: mscxData, to: url)
    }

    /// Render a `Score` to SMF (Standard MIDI File) bytes.
    public static func exportMIDI(score: Score) throws -> Data {
        let midiFile = try MidiRenderer.render(score: score)
        return try MidiWriter.write(midiFile)
    }
}
