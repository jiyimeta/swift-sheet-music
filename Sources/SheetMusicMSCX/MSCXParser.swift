import Foundation
import SheetMusicCore

/// Public façade that turns mscx XML bytes into a `Score`.
public enum MSCXParser {
    /// Parse uncompressed `.mscx` XML bytes into an in-memory `Score`.
    /// Throws `SheetMusicError.invalidXML` for ill-formed XML and
    /// `SheetMusicError.malformedScore` for missing required elements.
    public static func parse(_ data: Data) throws -> Score {
        let root = try XMLTreeParser.parse(data)
        return try Score.decode(root)
    }
}
