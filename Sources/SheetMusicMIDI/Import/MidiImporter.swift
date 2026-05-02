import Foundation
import SheetMusicCore

/// Public façade for reading SMF bytes into a `Score`.
///
/// The `parse` overloads run a six-pass pipeline:
///   1. `MidiReader` — SMF bytes → `MidiFile`
///   2. `TrackPartitioner` — split tracks into channel-coherent
///      slices (drums separated)
///   3. `SwingAnalyzer` — optional swing detection + resolver
///   4. `BarSegmenter` — split into per-measure events
///   5. `MeasureQuantizer` — D' onset-grid / tuplet fit
///   6. `ScoreAssembler` — voicing, ties, glissando, meta routing
public enum MidiImporter {
    public static func parse(
        _ midiData: Data,
        options: MidiImportOptions = .init(),
        sourceFilename: String? = nil
    ) throws -> Score {
        let file = try MidiReader.read(midiData)
        return try assembleSync(
            file: file, options: options, sourceFilename: sourceFilename
        )
    }

    public static func parse(
        _ midiData: Data,
        options: MidiImportOptions,
        sourceFilename: String? = nil
    ) async throws -> Score {
        let file = try MidiReader.read(midiData)
        return try await assembleAsync(
            file: file, options: options, sourceFilename: sourceFilename
        )
    }

    // MARK: - Internal entry points (filled in over the following tasks)

    static func assembleSync(
        file: MidiFile,
        options: MidiImportOptions,
        sourceFilename: String?
    ) throws -> Score {
        // Phases C–F implement the real pipeline. For now: emit a
        // Score with only the title resolved from `sourceFilename`.
        var meta: [String: String] = [:]
        if let title = sourceFilename, !title.isEmpty {
            meta["workTitle"] = title
        }
        return Score(division: file.division, metaTags: meta)
    }

    static func assembleAsync(
        file: MidiFile,
        options: MidiImportOptions,
        sourceFilename: String?
    ) async throws -> Score {
        try assembleSync(file: file, options: options, sourceFilename: sourceFilename)
    }
}
