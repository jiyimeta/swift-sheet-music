import Foundation
import SheetMusicCore
import SheetMusicXMLTools

/// Public façade that turns MusicXML bytes into a `Score`.
public enum MusicXMLParser {
    /// Parse uncompressed MusicXML bytes (`<score-partwise>` root) into a `Score`.
    public static func parse(_ data: Data) throws -> Score {
        let root = try XMLTreeParser.parse(data)
        return try Score.decodeMusicXML(root)
    }

    /// Parse a `.mxl` (zipped MusicXML) archive. Resolves the rootfile from
    /// `META-INF/container.xml` and delegates to `parse(_:)`.
    public static func parse(mxlData: Data) throws -> Score {
        let xmlBytes = try MXLReader.extractRootScore(mxlData: mxlData)
        return try parse(xmlBytes)
    }

    // NOTE: `parse(contentsOf: URL)` is out of scope for this library release;
    // it will be added alongside the other URL-based API overloads in a later spec.
}
