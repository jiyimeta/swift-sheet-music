import SheetMusicCore
import SheetMusicFoundation
import SheetMusicMIDI
import SheetMusicMSCX
import SheetMusicMusicXML

/// The one place that decides which parser a score payload belongs to.
///
/// Every format-dispatch in this package and its consumers routes here. That is the point of the target: a host that
/// has bytes and wants a `Score` should never have to spell the format table itself, because a second spelling is
/// only ever *nearly* right — it drifts the moment a format is added, and it drifts silently, since the failure is a
/// parse that returns `nil` rather than anything that refuses to compile.
///
/// Sniffing rather than trusting a file extension is deliberate. An extension is a claim made by whoever named the
/// file; the leading bytes are the file. It also means two images that both call this agree on what a given file is
/// *by construction*, which matters wherever a score is parsed twice independently (Folino's Android edit session
/// parses the same file in a second image, and the two copies must start from the same score).
///
/// Deliberately static and Foundation-only: it is linked into each image that needs it — including several separate
/// `.so`s in one Android process — and carries no state for those copies to disagree about.
public enum ScoreLoader {
    /// What [sniff](sniff(_:)) concluded the payload is.
    ///
    /// `mscz` covers every ZIP container, `.mscz` and `.mxl` alike: the two are told apart by trying to parse, not by
    /// their magic, which is identical. `unknown` is a real answer, not an error — the caller decides whether an
    /// unrecognized payload is a failure.
    public enum SniffedFormat: Sendable {
        case mscx, mscz, musicXML, midi, unknown
    }

    /// Inspects the leading bytes of `bytes` to decide which parser owns the payload.
    ///
    /// ZIP magic (`PK\x03\x04`) means a compressed container (`.mscz` or `.mxl`); `MThd` is the Standard MIDI File
    /// header chunk; XML is told apart by the root element appearing in the first 256 bytes.
    ///
    /// The three magics are mutually exclusive — `MThd` is neither the ZIP magic nor XML text — so no payload one
    /// case has claimed can be reclassified by a later one, and the order of these checks is therefore not
    /// load-bearing.
    public static func sniff(_ bytes: Data) -> SniffedFormat {
        if bytes.count >= 4,
           bytes[bytes.startIndex] == 0x50, bytes[bytes.startIndex + 1] == 0x4B,
           bytes[bytes.startIndex + 2] == 0x03, bytes[bytes.startIndex + 3] == 0x04
        {
            return .mscz
        }
        // Standard MIDI File: the "MThd" header chunk.
        if bytes.count >= 4,
           bytes[bytes.startIndex] == 0x4D, bytes[bytes.startIndex + 1] == 0x54,
           bytes[bytes.startIndex + 2] == 0x68, bytes[bytes.startIndex + 3] == 0x64
        {
            return .midi
        }
        // XML (with or without BOM). Distinguish mscx vs musicXML by root element name in the first 256 bytes.
        let prefix = bytes.prefix(256)
        if let text = String(data: prefix, encoding: .utf8) {
            if text.contains("<museScore") { return .mscx }
            if text.contains("<score-partwise") || text.contains("<score-timewise") {
                return .musicXML
            }
        }
        return .unknown
    }

    /// Parses `bytes` into a `Score`, choosing the parser by [sniff](sniff(_:)).
    ///
    /// - Parameters:
    ///   - bytes: Raw bytes of a `.mscx`, `.mscz`, `.musicxml`, `.mxl` or `.mid` payload.
    ///   - sourceFilename: Title fallback for Standard MIDI Files that carry no Track-Name meta, without its
    ///     extension. Ignored by every other format, which carry a title of their own. Pass it whenever the host
    ///     knows the name the user sees; a host that names the score itself afterwards can leave it `nil`.
    /// - Returns: The parsed score.
    /// - Throws: `SheetMusicError` from the underlying parser, or `SheetMusicError.malformedScore` when the payload
    ///   matches no known format.
    public static func loadScore(bytes: Data, sourceFilename: String? = nil) throws -> Score {
        switch sniff(bytes) {
        case .mscx:
            return try MSCXParser.parse(bytes)
        case .mscz:
            // A ZIP container is either `.mscz` or `.mxl`, and the magic cannot tell them apart. MuseScore first
            // because it is overwhelmingly the common case; the MXL path is the fallback rather than a peer so a
            // genuine `.mscz` never pays for the second attempt.
            do {
                return try MSCZReader.parse(bytes)
            } catch {
                return try MusicXMLParser.parse(mxlData: bytes)
            }
        case .musicXML:
            return try MusicXMLParser.parse(bytes)
        case .midi:
            return try MidiImporter.parse(bytes, options: .init(), sourceFilename: sourceFilename)
        case .unknown:
            throw SheetMusicError.malformedScore(
                ScoreFault(
                    code: "bridge.scoreFormat.unrecognized",
                    message: "unrecognized score format (not mscx/mscz/musicxml/mxl/mid)",
                ),
            )
        }
    }

    /// Reads the file at `url` and parses it, taking the MIDI title fallback from the file's own name.
    ///
    /// The convenience that most callers actually want: a host holding a path has the filename right there, and
    /// forgetting to pass it is how a `.mid` ends up titled after nothing at all.
    public static func loadScore(contentsOf url: URL) throws -> Score {
        try loadScore(
            bytes: Data(contentsOf: url),
            sourceFilename: url.deletingPathExtension().lastPathComponent,
        )
    }
}
