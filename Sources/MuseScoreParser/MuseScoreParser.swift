import Foundation

/// Top-level public API for the MuseScoreParser library.
public enum MuseScoreParser {
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
