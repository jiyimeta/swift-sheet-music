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
/// other auxiliary resources are written.
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
    ) throws -> Data {
        try validate(mainFileName: mainFileName)
        var writer = ZipWriter()
        do {
            try writer.add(
                path: containerPath,
                data: containerXML(forMainFileName: mainFileName),
                method: .deflate,
            )
            try writer.add(path: mainFileName, data: mscxData, method: .deflate)
        } catch let error as ZipError {
            throw SheetMusicError.corruptedContainer(
                reason: "failed to add entry: \(error)",
            )
        }
        return writer.finish()
    }

    public static func write(
        mscxData: Data,
        to url: URL,
        mainFileName: String = "score.mscx",
    ) throws {
        let bytes = try write(mscxData: mscxData, mainFileName: mainFileName)
        do {
            try bytes.write(to: url, options: .atomic)
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
            try bytes.write(to: url, options: .atomic)
        } catch {
            throw SheetMusicError.ioError(url: url, underlying: error)
        }
    }

    public static func write(
        score: Score, options: MSCXEncoderOptions,
        mainFileName: String = "score.mscx",
    ) throws -> Data {
        let mscxData = try MSCXEncoder.encode(score, options: options)
        return try write(mscxData: mscxData, mainFileName: mainFileName)
    }

    public static func write(
        score: Score, options: MSCXEncoderOptions, to url: URL,
        mainFileName: String = "score.mscx",
    ) throws {
        let bytes = try write(
            score: score, options: options, mainFileName: mainFileName,
        )
        do {
            try bytes.write(to: url, options: .atomic)
        } catch {
            throw SheetMusicError.ioError(url: url, underlying: error)
        }
    }

    private static func validate(mainFileName: String) throws {
        guard !mainFileName.isEmpty else {
            throw SheetMusicError.corruptedContainer(
                reason: "mainFileName must not be empty",
            )
        }
        guard !mainFileName.contains("/") else {
            throw SheetMusicError.corruptedContainer(
                reason: "mainFileName must not contain '/': \(mainFileName)",
            )
        }
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

    private static func xmlAttributeEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
