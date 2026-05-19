import Foundation
import SheetMusicCore
import SheetMusicMSCX
import SheetMusicMusicXML

/// Routes a raw byte payload (`.mscx`, `.mscz`, `.musicxml`, `.mxl`) to the
/// matching parser by sniffing the first few bytes. Returns the parsed Score
/// or throws SheetMusicError.
public enum ScoreBridge {
    public enum SniffedFormat {
        case mscx, mscz, musicXML, mxl, unknown
    }

    /// Inspect the leading bytes of `data` to determine what score format it
    /// contains. ZIP magic bytes (PK\x03\x04) indicate `.mscz` or `.mxl`;
    /// XML content is distinguished by the root element name found in the
    /// first 256 bytes.
    public static func sniff(_ bytes: Data) -> SniffedFormat {
        // ZIP (PK\x03\x04) — mscz or mxl.
        // The container distinction is left to the respective decoders;
        // we return .mscz for the common Android use-case.
        if bytes.count >= 4,
           bytes[0] == 0x50, bytes[1] == 0x4B,
           bytes[2] == 0x03, bytes[3] == 0x04
        {
            return .mscz
        }
        // XML (with or without BOM). Distinguish mscx vs musicXML by
        // root element name appearing in the first 256 bytes.
        let prefix = bytes.prefix(256)
        if let text = String(data: prefix, encoding: .utf8) {
            if text.contains("<museScore") { return .mscx }
            if text.contains("<score-partwise") || text.contains("<score-timewise") {
                return .musicXML
            }
        }
        return .unknown
    }

    /// Parse `bytes` into a `Score` by sniffing the format first.
    ///
    /// - Parameter bytes: Raw bytes from a `.mscx`, `.mscz`, `.musicxml`,
    ///   or `.mxl` file.
    /// - Returns: The parsed `Score`.
    /// - Throws: `SheetMusicError` on parse failure; `SheetMusicError.malformedScore`
    ///   when the format cannot be identified.
    public static func loadScore(bytes: Data) throws -> Score {
        switch sniff(bytes) {
        case .mscx:
            return try MSCXParser.parse(bytes)
        case .mscz:
            // .mscz is a ZIP container with an inner .mscx.
            // MSCZReader handles the ZIP unwrapping; MSCXParser only
            // accepts uncompressed XML. If MSCZReader rejects the bytes
            // (e.g. it's actually an .mxl archive), fall back to the
            // MusicXML MXL path.
            do {
                return try MSCZReader.parse(bytes)
            } catch {
                return try MusicXMLParser.parse(mxlData: bytes)
            }
        case .musicXML:
            return try MusicXMLParser.parse(bytes)
        case .mxl:
            return try MusicXMLParser.parse(mxlData: bytes)
        case .unknown:
            throw SheetMusicError.malformedScore(
                reason: "unrecognized score format (not mscx/mscz/musicxml/mxl)",
            )
        }
    }
}
