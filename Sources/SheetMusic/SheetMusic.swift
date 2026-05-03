import Foundation
@_exported import SheetMusicCore
@_exported import SheetMusicMIDI
@_exported import SheetMusicMSCX
@_exported import SheetMusicMusicXML
@_exported import SheetMusicPDF

/// Top-level convenience façade for the SheetMusic family of libraries.
///
/// `import SheetMusic` re-exports `SheetMusicCore`, `SheetMusicMSCX`,
/// `SheetMusicMusicXML`, and `SheetMusicMIDI` so all public types of the
/// typical "load score → export MIDI" pipeline are visible without
/// per-library imports.
public enum SheetMusic {
    /// Parse uncompressed `.mscx` bytes into a `Score`.
    public static func loadScore(mscxData: Data) throws -> Score {
        try MSCXParser.parse(mscxData)
    }

    /// Parse `.mscz` container bytes into a `Score` (main `.mscx` only).
    public static func loadScore(msczData: Data) throws -> Score {
        try MSCZReader.parse(msczData)
    }

    /// Parse uncompressed MusicXML bytes (`<score-partwise>` root) into a `Score`.
    public static func loadScore(musicXMLData: Data) throws -> Score {
        try MusicXMLParser.parse(musicXMLData)
    }

    /// Parse `.mxl` (zipped MusicXML) archive bytes into a `Score`.
    public static func loadScore(mxlData: Data) throws -> Score {
        try MusicXMLParser.parse(mxlData: mxlData)
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

    /// Parse SMF bytes (`.mid`) into a `Score`. Layout-related fields
    /// default since MIDI carries no layout. Title falls back to
    /// `sourceFilename` if no Track-Name meta is found.
    public static func loadScore(
        midiData: Data,
        options: MidiImportOptions = .init(),
        sourceFilename: String? = nil
    ) throws -> Score {
        try MidiImporter.parse(midiData, options: options, sourceFilename: sourceFilename)
    }

    /// Parse SMF bytes (`.mid`) into a `Score` asynchronously.
    /// Layout-related fields default since MIDI carries no layout.
    /// Title falls back to `sourceFilename` if no Track-Name meta is found.
    public static func loadScore(
        midiData: Data,
        options: MidiImportOptions,
        sourceFilename: String? = nil
    ) async throws -> Score {
        try await MidiImporter.parse(midiData, options: options, sourceFilename: sourceFilename)
    }

    /// Read an SMF file and parse into a `Score`. The filename
    /// (without extension) is used as the title fallback when the SMF
    /// has no Track-Name meta on Track 0.
    public static func loadScore(
        midiURL: URL, options: MidiImportOptions = .init()
    ) throws -> Score {
        let data = try Data(contentsOf: midiURL)
        return try MidiImporter.parse(
            data, options: options,
            sourceFilename: midiURL.deletingPathExtension().lastPathComponent
        )
    }

    /// Read an SMF file and parse into a `Score` asynchronously.
    /// The filename (without extension) is used as the title fallback
    /// when the SMF has no Track-Name meta on Track 0.
    public static func loadScore(
        midiURL: URL, options: MidiImportOptions = .init()
    ) async throws -> Score {
        let data = try Data(contentsOf: midiURL)
        return try await MidiImporter.parse(
            data, options: options,
            sourceFilename: midiURL.deletingPathExtension().lastPathComponent
        )
    }

    /// Read a `.pdf` file (vector PDF from MuseScore 3.x/4.x) and parse
    /// into a `Score`. CPU-bound; wrap with `Task { … }` if you need
    /// to keep the main thread responsive.
    public static func loadScore(
        pdfURL: URL,
        options: PDFImportOptions = .init()
    ) throws -> Score {
        try PDFImporter.parse(pdfURL: pdfURL, options: options)
    }

    /// Parse vector-PDF bytes into a `Score`.
    public static func loadScore(
        pdfData: Data,
        options: PDFImportOptions = .init()
    ) throws -> Score {
        try PDFImporter.parse(pdfData: pdfData, options: options)
    }
}
