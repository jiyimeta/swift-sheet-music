import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

/// Public façade that turns MusicXML bytes into a `Score`.
public enum MusicXMLParser {
    /// Parse uncompressed MusicXML bytes (`<score-partwise>` root) into a `Score`.
    public static func parse(_ data: Data) throws -> Score {
        try parse(data, options: .default)
    }

    /// Parse uncompressed MusicXML bytes with explicit import options.
    ///
    /// `<words>` and `<rehearsal>` keep their mixed content: the tree trims `text` once an element closes, but
    /// MuseScore keeps a text's trailing space (`testTempoTextSpace1_ref.mscx`), so the words are read from it.
    package static func parse(_ data: Data, options: MusicXMLImportOptions) throws -> Score {
        let root = try XMLTreeParser.parse(data, preservingMixedContentIn: mixedContentElements)
        return try Score.decodeMusicXML(root, options: options)
    }

    /// The elements whose characters are read untrimmed, as MuseScore reads them.
    package static let mixedContentElements: Set = ["words", "rehearsal"]

    /// Parse a `.mxl` (zipped MusicXML) archive. Resolves the rootfile from
    /// `META-INF/container.xml` and delegates to `parse(_:)`.
    public static func parse(mxlData: Data) throws -> Score {
        let xmlBytes = try MXLReader.extractRootScore(mxlData: mxlData)
        return try parse(xmlBytes)
    }

    // NOTE: `parse(contentsOf: URL)` is out of scope for this library release;
    // it will be added alongside the other URL-based API overloads in a later spec.
}
