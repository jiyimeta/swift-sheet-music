import Foundation
import SheetMusicCore
import SheetMusicZip

/// Packages already-serialized `.mscx` XML bytes into a minimal `.mscz`
/// (ZIP) container.
///
/// This is the low-level writer — it does NOT serialize a `Score`.
/// The high-level overloads delegate to `MSCXEncoder` to produce the
/// XML bytes, then wrap them. The produced archive contains only the
/// provided XML bytes at the given `mainFileName`; no
/// `META-INF/container.xml`, no auxiliary resources. MuseScore's own
/// `MscReader::readScoreFile` resolves the main score by entry name,
/// so the minimal archive round-trips through both this library and
/// MuseScore Studio.
public enum MSCZWriter {
    public static func write(
        mscxData: Data,
        mainFileName: String = "score.mscx",
    ) throws -> Data {
        try validate(mainFileName: mainFileName)
        var writer = ZipWriter()
        do {
            try writer.add(path: mainFileName, data: mscxData, method: .deflate)
        } catch let error as ZipError {
            throw SheetMusicError.corruptedContainer(
                reason: "failed to add entry \(mainFileName): \(error)",
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
}
