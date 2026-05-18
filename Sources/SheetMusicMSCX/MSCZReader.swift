#if !os(Android)
    import Foundation
    import SheetMusicCore
    import ZIPFoundation

    /// Reads `.mscz` (ZIP) containers and returns the `Score` contained
    /// in the main `.mscx` entry. When the archive ships an
    /// `audiosettings.json` (MuseScore 4), per-part preset overrides are
    /// merged into the score so consumers see the sounds MuseScore
    /// actually plays. Other auxiliary resources (style, thumbnails,
    /// pictures, excerpts, …) are ignored.
    ///
    /// Mirrors `mu::engraving::MscReader::mainFileName` /
    /// `::readScoreFile`: prefer the exact name `score.mscx`, and fall
    /// back to the first `.mscx` entry at archive root. Filename-based
    /// main-name matching (using the archive's own file name) is skipped
    /// because the `Data` overload has no filename context.
    public enum MSCZReader {
        /// Parse `.mscz` bytes into a `Score`.
        public static func parse(_ data: Data) throws -> Score {
            let archive: Archive
            do {
                archive = try Archive(data: data, accessMode: .read)
            } catch {
                throw SheetMusicError.corruptedContainer(
                    reason: "could not open ZIP: \(error)",
                )
            }
            let entry = try resolveMainEntry(in: archive)
            let mscxData = try extract(entry, from: archive)
            let score = try MSCXParser.parse(mscxData)
            let settings = audioSettings(in: archive)
            return settings.map { apply($0, to: score) } ?? score
        }

        /// Look up `audiosettings.json` at the archive root and parse it.
        /// Returns nil when the entry is absent or the JSON is unreadable
        /// — both are non-fatal: the score reverts to its mscx-declared
        /// channel programs.
        private static func audioSettings(in archive: Archive) -> AudioSettings? {
            guard let entry = archive["audiosettings.json"],
                  entry.type == .file,
                  let data = try? extract(entry, from: archive),
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
        /// the right fallback when the playback host can't honour MS
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

        private static func resolveMainEntry(in archive: Archive) throws -> Entry {
            if let exact = archive["score.mscx"], exact.type == .file {
                return exact
            }
            for entry in archive where entry.type == .file {
                let path = entry.path
                guard !path.contains("/") else { continue }
                if path.lowercased().hasSuffix(".mscx") {
                    return entry
                }
            }
            throw SheetMusicError.corruptedContainer(
                reason: "no main .mscx entry found in archive",
            )
        }

        private static func extract(_ entry: Entry, from archive: Archive) throws -> Data {
            var buffer = Data()
            do {
                _ = try archive.extract(entry) { chunk in
                    buffer.append(chunk)
                }
            } catch {
                throw SheetMusicError.corruptedContainer(
                    reason: "failed to extract \(entry.path): \(error)",
                )
            }
            return buffer
        }
    }
#endif
