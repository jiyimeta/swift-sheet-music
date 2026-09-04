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
    /// A parsed score together with the parser's non-fatal findings.
    ///
    /// Deliberately not `MSCXParseResult`: that type belongs to one format's parser, and naming it
    /// here would make every caller of the dispatcher import `SheetMusicMSCX` to spell the return
    /// type of a function that also handles MusicXML and MIDI.
    public struct LoadedScore: Sendable {
        public let score: Score
        /// Empty for every format but MuseScore's, which is the only one with a diagnostic channel.
        public let diagnostics: [ScoreDiagnostic]

        public init(score: Score, diagnostics: [ScoreDiagnostic]) {
            self.score = score
            self.diagnostics = diagnostics
        }
    }

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
        try loadScoreWithDiagnostics(bytes: bytes, sourceFilename: sourceFilename).score
    }

    /// [loadScore](loadScore(bytes:sourceFilename:)) plus whatever the parser had to say about the
    /// payload on the way through.
    ///
    /// The diagnostic channel is where the parser's *embellishment* policy surfaces: an unknown
    /// tremolo subtype or an unrepresentable ornament is dropped so the rest of the score still
    /// loads, and this is the only way a host finds out it happened (see ARCHITECTURE.md's "Parser
    /// policy"). A host that silently discards these is choosing not to tell its user that part of
    /// their file did not survive the trip.
    ///
    /// Only MuseScore payloads produce diagnostics today. MusicXML has no equivalent channel and
    /// the MIDI importer none either, so both answer with an empty array rather than a lie — the
    /// same asymmetry ARCHITECTURE.md records.
    ///
    /// This is the *one* switch over `SniffedFormat`; `loadScore` is a projection of it. A second
    /// spelling of the format table is what this whole target exists to prevent, and "the
    /// diagnostics variant forgot the format someone just added" is exactly the silent drift the
    /// type's own doc comment warns about.
    public static func loadScoreWithDiagnostics(
        bytes: Data, sourceFilename: String? = nil,
    ) throws -> LoadedScore {
        switch sniff(bytes) {
        case .mscx:
            let result = try MSCXParser.parseWithDiagnostics(bytes)
            return LoadedScore(score: result.score, diagnostics: result.diagnostics)
        case .mscz:
            // A ZIP container is either `.mscz` or `.mxl`, and the magic cannot tell them apart. MuseScore first
            // because it is overwhelmingly the common case; the MXL path is the fallback rather than a peer so a
            // genuine `.mscz` never pays for the second attempt.
            do {
                let result = try MSCZReader.parseWithDiagnostics(bytes)
                return LoadedScore(score: result.score, diagnostics: result.diagnostics)
            } catch let error as SheetMusicError where error.isMuseScoreDocumentFault {
                // The container did yield a `<museScore>` document and the
                // MuseScore reader is the one that has an opinion about it.
                // Trying MXL anyway replaces that opinion with "no
                // <score-partwise>", which sends the caller looking for a
                // MusicXML problem in a MuseScore file.
                throw error
            } catch {
                return try LoadedScore(score: MusicXMLParser.parse(mxlData: bytes), diagnostics: [])
            }
        case .musicXML:
            return try LoadedScore(score: MusicXMLParser.parse(bytes), diagnostics: [])
        case .midi:
            let score = try MidiImporter.parse(
                bytes, options: .init(), sourceFilename: sourceFilename,
            )
            return LoadedScore(score: score, diagnostics: [])
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

extension SheetMusicError {
    /// Whether this error says something about a MuseScore document
    /// rather than about the container it arrived in.
    ///
    /// A `mscx.*` fault is only ever raised once the reader is looking
    /// at a parsed `<museScore>` tree, so it positively identifies the
    /// payload; a `.mxl` reaching the same code path fails on the
    /// container or the missing main entry instead, with a `zip.*` or
    /// `mscz.*` fault, and still deserves the MusicXML attempt.
    fileprivate var isMuseScoreDocumentFault: Bool {
        guard case let .malformedScore(fault) = self else { return false }
        return fault.code.hasPrefix("mscx.")
    }
}
