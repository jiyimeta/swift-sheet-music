import Foundation
import SheetMusicCore
import SheetMusicMIDI
import SheetMusicMSCX
import SheetMusicMusicXML

/// Routes a raw byte payload (`.mscx`, `.mscz`, `.musicxml`, `.mxl`, `.mid`)
/// to the matching parser by sniffing the first few bytes. Returns the parsed
/// Score or throws SheetMusicError.
public enum ScoreBridge {
    public enum SniffedFormat {
        case mscx, mscz, musicXML, midi, unknown
    }

    /// Inspect the leading bytes of `data` to determine what score format it
    /// contains. ZIP magic bytes (PK\x03\x04) indicate a compressed container
    /// (`.mscz` or `.mxl`); `MThd` is the Standard MIDI File header chunk;
    /// XML content is distinguished by the root element name found in the
    /// first 256 bytes. The mscz/mxl distinction is deferred to `loadScore`,
    /// which tries MSCZReader first and falls back to the MXL path on failure.
    ///
    /// The four magics are mutually exclusive: `MThd` is neither the ZIP magic
    /// nor XML text, so it can never reclassify a payload one of the other
    /// cases already claimed.
    public static func sniff(_ bytes: Data) -> SniffedFormat {
        if bytes.count >= 4,
           bytes[0] == 0x50, bytes[1] == 0x4B,
           bytes[2] == 0x03, bytes[3] == 0x04
        {
            return .mscz
        }
        // Standard MIDI File: the "MThd" header chunk.
        if bytes.count >= 4,
           bytes[0] == 0x4D, bytes[1] == 0x54,
           bytes[2] == 0x68, bytes[3] == 0x64
        {
            return .midi
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
    ///   `.mxl`, or `.mid` file.
    /// - Returns: The parsed `Score`.
    /// - Throws: `SheetMusicError` on parse failure; `SheetMusicError.malformedScore`
    ///   when the format cannot be identified.
    public static func loadScore(bytes: Data) throws -> Score {
        switch sniff(bytes) {
        case .mscx:
            return try MSCXParser.parse(bytes)
        case .mscz:
            // ZIP container — could be .mscz or .mxl. Try MSCZReader
            // first (the common Android case); on failure try the MXL
            // path before giving up.
            do {
                return try MSCZReader.parse(bytes)
            } catch {
                return try MusicXMLParser.parse(mxlData: bytes)
            }
        case .musicXML:
            return try MusicXMLParser.parse(bytes)
        case .midi:
            // The host names the score from the picker's display name, so the
            // importer needs no filename hint here.
            return try MidiImporter.parse(bytes)
        case .unknown:
            throw SheetMusicError.malformedScore(
                reason: "unrecognized score format (not mscx/mscz/musicxml/mxl/mid)",
            )
        }
    }
}
