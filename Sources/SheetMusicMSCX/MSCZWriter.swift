import SheetMusicCore
import SheetMusicFoundation
import SheetMusicZip

/// Packages already-serialized `.mscx` XML bytes into a minimal `.mscz`
/// (ZIP) container.
///
/// This is the low-level writer — it does NOT serialize a `Score`.
/// The high-level overloads delegate to `MSCXEncoder` to produce the
/// XML bytes, then wrap them. The produced archive contains two
/// entries: `META-INF/container.xml` pointing at the main score, and
/// the score itself at the given `mainFileName`. No thumbnails or
/// other auxiliary resources are written of this writer's own accord —
/// a host that keeps a sidecar in the container passes it as
/// `extraEntries`, which are appended after those two in the order
/// given.
///
/// `META-INF/container.xml` is required for MuseScore 3 to locate the
/// score (its reader looks up the rootfile via container.xml only).
/// MuseScore 4 reads container.xml too, so the archive round-trips
/// through both versions.
public enum MSCZWriter {
    private static let containerPath = "META-INF/container.xml"

    public static func write(
        mscxData: Data,
        mainFileName: String = "score.mscx",
        extraEntries: [MSCZExtraEntry] = [],
    ) throws -> Data {
        try validate(mainFileName: mainFileName)
        try validate(extraEntries: extraEntries, mainFileName: mainFileName)
        var writer = ZipWriter()
        do {
            try writer.add(
                path: containerPath,
                data: containerXML(forMainFileName: mainFileName),
                method: .deflate,
            )
            try writer.add(path: mainFileName, data: mscxData, method: .deflate)
            for entry in extraEntries {
                try writer.add(
                    path: entry.path, data: entry.data, method: entry.compression.zipMethod,
                )
            }
        } catch let error as ZipError {
            throw SheetMusicError.corruptedContainer(
                ScoreFault(
                    code: error.faultCode,
                    message: "failed to add entry: \(error)",
                ),
            )
        }
        return writer.finish()
    }

    public static func write(
        mscxData: Data,
        to url: URL,
        mainFileName: String = "score.mscx",
        extraEntries: [MSCZExtraEntry] = [],
    ) throws {
        let bytes = try write(
            mscxData: mscxData,
            mainFileName: mainFileName,
            extraEntries: extraEntries,
        )
        do {
            try bytes.write(to: url, options: .atomicIfAvailable)
        } catch {
            throw SheetMusicError.ioError(url: url, underlying: error)
        }
    }

    public static func write(
        score: Score, mainFileName: String = "score.mscx",
    ) throws -> Data {
        let mscxData = try MSCXEncoder.encode(score)
        return try write(mscxData: mscxData, mainFileName: mainFileName)
    }

    public static func write(
        score: Score, to url: URL, mainFileName: String = "score.mscx",
    ) throws {
        let bytes = try write(score: score, mainFileName: mainFileName)
        do {
            try bytes.write(to: url, options: .atomicIfAvailable)
        } catch {
            throw SheetMusicError.ioError(url: url, underlying: error)
        }
    }

    public static func write(
        score: Score, options: MSCXEncoderOptions,
        mainFileName: String = "score.mscx",
        extraEntries: [MSCZExtraEntry] = [],
    ) throws -> Data {
        let mscxData = try MSCXEncoder.encode(score, options: options)
        return try write(
            mscxData: mscxData,
            mainFileName: mainFileName,
            extraEntries: extraEntries,
        )
    }

    public static func write(
        score: Score, options: MSCXEncoderOptions, to url: URL,
        mainFileName: String = "score.mscx",
        extraEntries: [MSCZExtraEntry] = [],
    ) throws {
        let bytes = try write(
            score: score,
            options: options,
            mainFileName: mainFileName,
            extraEntries: extraEntries,
        )
        do {
            try bytes.write(to: url, options: .atomicIfAvailable)
        } catch {
            throw SheetMusicError.ioError(url: url, underlying: error)
        }
    }

    private static func validate(mainFileName: String) throws {
        guard !mainFileName.isEmpty else {
            throw SheetMusicError.corruptedContainer(
                ScoreFault(
                    code: "mscz.mainFileName.empty",
                    message: "mainFileName must not be empty",
                ),
            )
        }
        guard !mainFileName.contains("/") else {
            throw SheetMusicError.corruptedContainer(
                ScoreFault(
                    code: "mscz.mainFileName.containsSlash",
                    message: "mainFileName must not contain '/': \(mainFileName)",
                    location: mainFileName,
                ),
            )
        }
    }

    /// Reject a host's sidecar paths that would collide with the container's own two entries, name
    /// a location outside the archive, or shadow each other. Every rule is checked before a single
    /// byte is written, so a rejected call leaves no half-built archive.
    private static func validate(
        extraEntries: [MSCZExtraEntry], mainFileName: String,
    ) throws {
        var seen: Set<String> = []
        for entry in extraEntries {
            let path = entry.path
            guard !path.isEmpty else {
                throw fault("mscz.extraEntry.emptyPath", "extra entry path must not be empty")
            }
            guard !path.hasPrefix("/") else {
                throw fault(
                    "mscz.extraEntry.absolutePath",
                    "extra entry path must be relative: \(path)",
                    location: path,
                )
            }
            guard !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
            else {
                throw fault(
                    "mscz.extraEntry.parentSegment",
                    "extra entry path must not contain a '..' segment: \(path)",
                    location: path,
                )
            }
            guard path != containerPath else {
                throw fault(
                    "mscz.extraEntry.reservedPath",
                    "\(containerPath) is written by this writer and cannot be an extra entry",
                    location: path,
                )
            }
            guard path != mainFileName else {
                throw fault(
                    "mscz.extraEntry.mainFileNameCollision",
                    "extra entry path collides with the main score entry: \(path)",
                    location: path,
                )
            }
            guard seen.insert(path).inserted else {
                throw fault(
                    "mscz.extraEntry.duplicatePath",
                    "duplicate extra entry path: \(path)",
                    location: path,
                )
            }
        }
    }

    private static func fault(
        _ code: String, _ message: String, location: String? = nil,
    ) -> SheetMusicError {
        .corruptedContainer(ScoreFault(code: code, message: message, location: location))
    }

    /// Emit the OPF-style `META-INF/container.xml` that points at the main
    /// score entry. Mirrors the format MuseScore Studio writes:
    /// a single `<rootfile>` with a `full-path` attribute, no media-type.
    private static func containerXML(forMainFileName mainFileName: String) -> Data {
        let escaped = xmlAttributeEscape(mainFileName)
        return Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <container>
          <rootfiles>
            <rootfile full-path="\(escaped)"/>
          </rootfiles>
        </container>
        """.utf8)
    }

    /// A single pass rather than five `replacingOccurrences` calls, which
    /// are umbrella-only and so unavailable on wasm. Output is unchanged:
    /// the chained form replaced `&` first, so the ampersands the later
    /// replacements introduced were never re-escaped either.
    private static func xmlAttributeEscape(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&apos;"
            default: escaped.append(character)
            }
        }
        return escaped
    }
}
