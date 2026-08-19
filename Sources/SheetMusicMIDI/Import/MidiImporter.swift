import SheetMusicCore
import SheetMusicFoundation

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
        sourceFilename: String? = nil,
    ) throws -> Score {
        let file = try MidiReader.read(midiData)
        return try assembleSync(
            file: file, options: options, sourceFilename: sourceFilename,
        )
    }

    public static func parse(
        _ midiData: Data,
        options: MidiImportOptions,
        sourceFilename: String? = nil,
    ) async throws -> Score {
        let file = try MidiReader.read(midiData)
        return try await assembleAsync(
            file: file, options: options, sourceFilename: sourceFilename,
        )
    }

    // MARK: - Internal entry points

    static func assembleSync(
        file: MidiFile,
        options: MidiImportOptions,
        sourceFilename: String?,
    ) throws -> Score {
        let imports = partition(file)
        let timeline = buildBarTimeline(imports: imports, division: file.division)
        let swung = imports.map { track -> ImportTrack in
            guard let resolve = options.resolveSwing else { return track }
            return analyzeSwing(
                track: track, timeline: timeline,
                division: file.division, resolve: resolve,
            )
        }
        return buildScore(
            file: file, imports: swung, timeline: timeline,
            options: options, sourceFilename: sourceFilename,
        )
    }

    static func assembleAsync(
        file: MidiFile,
        options: MidiImportOptions,
        sourceFilename: String?,
    ) async throws -> Score {
        if options.resolveSwingAsync == nil {
            return try assembleSync(
                file: file, options: options, sourceFilename: sourceFilename,
            )
        }
        let imports = partition(file)
        let timeline = buildBarTimeline(imports: imports, division: file.division)
        var swung: [ImportTrack] = []
        for track in imports {
            if let resolveAsync = options.resolveSwingAsync {
                await swung.append(asyncSwing(
                    track: track, timeline: timeline,
                    division: file.division, resolve: resolveAsync,
                ))
            } else {
                swung.append(track)
            }
        }
        return buildScore(
            file: file, imports: swung, timeline: timeline,
            options: options, sourceFilename: sourceFilename,
        )
    }

    static func asyncSwing(
        track: ImportTrack,
        timeline: BarTimeline,
        division: Int,
        resolve: @Sendable (SwingDetection) async -> SwingResolution,
    ) async -> ImportTrack {
        guard let detection = detectSwing(
            track: track, timeline: timeline, division: division,
        ) else { return track }
        switch await resolve(detection) {
        case .treatAsWritten: return track
        case .treatAsSwing:
            let beat = (division * 4) / 4
            return straighten(track: track, beat: beat)
        }
    }
}
