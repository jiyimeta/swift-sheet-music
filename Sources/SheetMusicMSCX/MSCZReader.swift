import Foundation
import SheetMusicCore
import ZIPFoundation

/// Reads `.mscz` (ZIP) containers and returns the `Score` contained
/// in the main `.mscx` entry. Auxiliary resources inside the archive
/// (style, thumbnails, pictures, excerpts, audio, …) are ignored in
/// this release.
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
                reason: "could not open ZIP: \(error)"
            )
        }
        let entry = try resolveMainEntry(in: archive)
        let mscxData = try extract(entry, from: archive)
        return try MSCXParser.parse(mscxData)
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
            reason: "no main .mscx entry found in archive"
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
                reason: "failed to extract \(entry.path): \(error)"
            )
        }
        return buffer
    }
}
