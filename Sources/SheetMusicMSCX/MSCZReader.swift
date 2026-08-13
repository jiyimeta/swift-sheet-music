import SheetMusicCore
import SheetMusicFoundation
import SheetMusicZip

/// Reads `.mscz` (ZIP) containers and returns the `Score` contained in
/// the main `.mscx` entry. When the archive ships an
/// `audiosettings.json` (MuseScore 4), per-part preset overrides are
/// merged into the score so consumers see the sounds MuseScore actually
/// plays. Other auxiliary resources (style, thumbnails, pictures,
/// excerpts, …) are ignored.
///
/// Mirrors `mu::engraving::MscReader::mainFileName` /
/// `::readScoreFile`: prefer the exact name `score.mscx`, and fall back
/// to the first `.mscx` entry at archive root. Filename-based main-name
/// matching (using the archive's own file name) is skipped because the
/// `Data` overload has no filename context.
public enum MSCZReader {
    /// Parse `.mscz` bytes into a `Score`.
    public static func parse(_ data: Data) throws -> Score {
        let reader = try openReader(data)
        let mainPath = try resolveMainPath(in: reader)
        let mscxData: Data
        do {
            mscxData = try reader.read(path: mainPath)
        } catch let error as ZipError {
            throw SheetMusicError.corruptedContainer(
                reason: "failed to extract \(mainPath): \(error)",
            )
        }
        let score = try MSCXParser.parse(mscxData)
        let settings = audioSettings(in: reader)
        return settings.map { apply($0, to: score) } ?? score
    }

    /// Read `.mscz` bytes from a file URL and parse into a `Score`.
    /// I/O failures are wrapped in `SheetMusicError.ioError`.
    public static func parse(contentsOf url: URL) throws -> Score {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SheetMusicError.ioError(url: url, underlying: error)
        }
        return try parse(data)
    }

    /// Parse `.mscz` bytes, returning the score with non-fatal
    /// anomalies. Behaves like `parse(_:)` but surfaces diagnostics
    /// from the inner MSCX decode.
    public static func parseWithDiagnostics(
        _ data: Data,
    ) throws -> MSCXParseResult {
        let reader = try openReader(data)
        let mainPath = try resolveMainPath(in: reader)
        let mscxData: Data
        do {
            mscxData = try reader.read(path: mainPath)
        } catch let error as ZipError {
            throw SheetMusicError.corruptedContainer(
                reason: "failed to extract \(mainPath): \(error)",
            )
        }
        let inner = try MSCXParser.parseWithDiagnostics(mscxData)
        let settings = audioSettings(in: reader)
        let finalScore = settings.map { apply($0, to: inner.score) } ?? inner.score
        return MSCXParseResult(score: finalScore, diagnostics: inner.diagnostics)
    }

    /// Read `.mscz` bytes from a file URL and parse with diagnostics.
    public static func parseWithDiagnostics(
        contentsOf url: URL,
    ) throws -> MSCXParseResult {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SheetMusicError.ioError(url: url, underlying: error)
        }
        return try parseWithDiagnostics(data)
    }

    private static func openReader(_ data: Data) throws -> ZipReader {
        do {
            return try ZipReader(data: data)
        } catch let error as ZipError {
            throw SheetMusicError.corruptedContainer(
                reason: "could not open ZIP: \(error)",
            )
        }
    }

    private static func resolveMainPath(in reader: ZipReader) throws -> String {
        if reader.contains(path: "score.mscx") {
            return "score.mscx"
        }
        // Sorted for determinism.
        let candidates = reader.entries.keys
            .filter { !$0.contains("/") && $0.lowercased().hasSuffix(".mscx") }
            .sorted()
        guard let first = candidates.first else {
            throw SheetMusicError.corruptedContainer(
                reason: "no main .mscx entry found in archive",
            )
        }
        return first
    }

    /// Look up `audiosettings.json` at the archive root and parse it.
    /// Returns nil when the entry is absent or the JSON is unreadable
    /// — both are non-fatal: the score reverts to its mscx-declared
    /// channel programs.
    private static func audioSettings(in reader: ZipReader) -> AudioSettings? {
        guard reader.contains(path: "audiosettings.json"),
              let data = try? reader.read(path: "audiosettings.json"),
              let settings = try? AudioSettings.parse(data)
        else { return nil }
        return settings
    }

    /// Override each part's primary `InstrumentChannel` program /
    /// bank with the matching preset from `audiosettings.json`.
    /// Parts without a corresponding entry — or with an entry that
    /// doesn't nominate a `presetProgram` (e.g. drumset rows) — are
    /// left untouched.
    ///
    /// Drumset parts (`useDrumset == true`) are also skipped even when
    /// the entry carries a `presetProgram`: MuseScore 4's MS Basic
    /// addresses drum kits via `presetBank=128, presetProgram=N` where
    /// N selects a kit variant ("Standard", "Standard 4", …). That
    /// addressing is MS-Basic-specific and doesn't translate to a
    /// useful preset in third-party SoundFonts (e.g. MuseScore_General
    /// has no preset at SF2 bank LSB 128). The mscx-declared channel
    /// (typically `<program value="0"/>` = GM Standard Drum Kit) is
    /// the right fallback when the playback host can't honor MS
    /// Basic's kit variants.
    private static func apply(
        _ settings: AudioSettings, to score: Score,
    ) -> Score {
        guard !settings.presets.isEmpty else { return score }
        var result = score
        for partIdx in result.parts.indices {
            guard
                let preset = settings.presets[result.parts[partIdx].id],
                !result.parts[partIdx].instrument.channels.isEmpty,
                !result.parts[partIdx].instrument.useDrumset
            else { continue }
            if let program = preset.program {
                result.parts[partIdx].instrument.channels[0].program = program
            }
            if let bank = preset.bank {
                result.parts[partIdx].instrument.channels[0].bank = bank
            }
        }
        return result
    }
}
