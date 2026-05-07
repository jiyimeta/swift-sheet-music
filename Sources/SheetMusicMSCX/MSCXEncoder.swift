import Foundation
import SheetMusicCore
import SheetMusicXMLTools

/// Public façade that turns a `Score` into `.mscx` XML bytes.
///
/// Reverse of `MSCXParser.parse`. The contract is a **semantic**
/// round-trip: re-parsing the output via `MSCXParser` yields a `Score`
/// equal to the input under `==`. Byte-level parity with MuseScore
/// Studio's writer is not a goal.
public enum MSCXEncoder {
    /// Serialize a `Score` to `.mscx` XML bytes.
    public static func encode(_ score: Score) throws -> Data {
        let root = score.encode()
        return XMLTreeSerializer.serialize(root)
    }

    /// Serialize a `Score` and write the resulting `.mscx` to a file URL.
    public static func encode(_ score: Score, to url: URL) throws {
        let bytes = try encode(score)
        do {
            try bytes.write(to: url, options: .atomic)
        } catch {
            throw SheetMusicError.ioError(url: url, underlying: error)
        }
    }
}
