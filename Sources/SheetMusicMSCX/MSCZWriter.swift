import Foundation
import SheetMusicCore
#if !os(Android)
    import ZIPFoundation
#endif

/// Packages already-serialized `.mscx` XML bytes into a minimal
/// `.mscz` (ZIP) container.
///
/// This is the low-level writer — it does NOT serialize a `Score`.
/// A high-level `write(score:)` overload is out of scope until a
/// `Score → mscx XML` encoder exists. The produced archive contains
/// only the provided XML bytes at the given `mainFileName`; no
/// `META-INF/container.xml`, no auxiliary resources. MuseScore's own
/// `MscReader::readScoreFile` resolves the main score by entry name,
/// so the minimal archive round-trips through both this library and
/// MuseScore Studio.
///
/// On Android (Phase 1), `.mscz` is not yet supported. Use `.mscx`
/// (unzipped) output instead. A future phase will lift this restriction
/// when ZIPFoundation gains Android support.
public enum MSCZWriter {
    /// Package `.mscx` XML bytes into `.mscz` bytes.
    public static func write(
        mscxData: Data,
        mainFileName: String = "score.mscx",
    ) throws -> Data {
        #if os(Android)
            throw SheetMusicError.unsupportedFeature(
                name: "MSCZ (zipped)",
                location: "MSCZWriter: ZIP containers are not supported on Android in Phase 1",
            )
        #else
            try validate(mainFileName: mainFileName)
            let archive: Archive
            do {
                archive = try Archive(accessMode: .create)
            } catch {
                throw SheetMusicError.corruptedContainer(
                    reason: "could not create archive: \(error)",
                )
            }
            do {
                try archive.addEntry(
                    with: mainFileName,
                    type: .file,
                    uncompressedSize: Int64(mscxData.count),
                    compressionMethod: .deflate,
                ) { position, size in
                    let start = Int(position)
                    let end = min(start + size, mscxData.count)
                    return mscxData.subdata(in: start ..< end)
                }
            } catch {
                throw SheetMusicError.corruptedContainer(
                    reason: "failed to add entry \(mainFileName): \(error)",
                )
            }
            guard let bytes = archive.data else {
                throw SheetMusicError.corruptedContainer(
                    reason: "archive produced no bytes",
                )
            }
            return bytes
        #endif
    }

    /// Package `.mscx` XML bytes and write the resulting `.mscz` to a file URL.
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

    /// Serialize a `Score` to `.mscx` and package the result as
    /// `.mscz` bytes.
    public static func write(
        score: Score, mainFileName: String = "score.mscx",
    ) throws -> Data {
        let mscxData = try MSCXEncoder.encode(score)
        return try write(mscxData: mscxData, mainFileName: mainFileName)
    }

    /// Serialize a `Score` to `.mscx` and write the resulting
    /// `.mscz` to a file URL.
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

    /// Serialize a `Score` with options and package as `.mscz` bytes.
    public static func write(
        score: Score, options: MSCXEncoderOptions,
        mainFileName: String = "score.mscx",
    ) throws -> Data {
        let mscxData = try MSCXEncoder.encode(score, options: options)
        return try write(mscxData: mscxData, mainFileName: mainFileName)
    }

    /// Serialize a `Score` with options and write the resulting
    /// `.mscz` to a file URL.
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

    #if !os(Android)
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
    #endif
}
