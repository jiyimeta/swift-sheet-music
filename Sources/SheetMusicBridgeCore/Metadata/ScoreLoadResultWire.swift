import SheetMusicCore
import SheetMusicFoundation
import Wirelet

/// One non-fatal finding from the parser.
///
/// `severity`: 0 = info, 1 = warning — the same numbering `PdfDiagnosticWire` uses, on purpose. Two
/// diagnostic surfaces reaching one host with opposite severity numbering is the kind of difference
/// that is only ever discovered by a user being shown a warning as an aside.
@WireFormat
public struct ScoreDiagnosticWire: Equatable {
    public let severity: Int32
    /// Stable dotted identifier, e.g. `mscx.tremolo.unknownSubtype`. This is the localization key;
    /// `message` is not.
    public let code: String
    /// English text for logs. Never UI copy — a host localizes from `code`.
    public let message: String
    /// Best-effort location, e.g. `measure 12, voice 1, Tremolo`. Empty when the parser could not
    /// derive one cheaply (Swift's `nil`, flattened — the wire has no reason to distinguish an
    /// absent location from an empty one, and a host renders both the same way).
    public let location: String

    public init(severity: Int32, code: String, message: String, location: String) {
        self.severity = severity
        self.code = code
        self.message = message
        self.location = location
    }
}

/// Result of loading a score: the handle, why it failed if it did, and what the parser had to say
/// about the payload on the way through.
///
/// `nativeLoadScore` answers `0` for every failure, which tells a host that something went wrong and
/// nothing about what — a corrupt ZIP, an unrecognized format and a structurally invalid `<Measure>`
/// are one answer. An Apple host gets a `SheetMusicError` carrying a `ScoreFault` whose dotted `code`
/// is a localization key. This is that, across the wire.
///
/// The diagnostics half matters just as much and is easier to miss: the parsers are permissive by
/// design, so an unknown ornament subtype is *dropped* and the score still loads. Without this
/// channel an Android host cannot tell its user that part of their file did not survive the trip.
@WireFormat
public struct ScoreLoadResultWire: Equatable {
    /// `0` when the load failed. Non-zero handles must be released with `nativeReleaseScore`.
    public let scoreHandle: Int64
    /// `SheetMusicError.code` — the stable dotted identifier. Empty on success.
    public let faultCode: String
    /// `SheetMusicError.developerDescription`. Log context, never UI copy. Empty on success.
    public let faultMessage: String
    /// Non-fatal findings. Only MuseScore payloads produce these; MusicXML has no equivalent channel
    /// and the MIDI importer none either, so both answer empty rather than implying a clean parse.
    public let diagnostics: [ScoreDiagnosticWire]

    public init(
        scoreHandle: Int64,
        faultCode: String,
        faultMessage: String,
        diagnostics: [ScoreDiagnosticWire],
    ) {
        self.scoreHandle = scoreHandle
        self.faultCode = faultCode
        self.faultMessage = faultMessage
        self.diagnostics = diagnostics
    }
}

extension ScoreDiagnosticWire {
    /// `severity` for a `ScoreDiagnostic.Severity`, matching `PdfDiagnosticWire`'s numbering.
    public static func severityValue(for severity: ScoreDiagnostic.Severity) -> Int32 {
        switch severity {
        case .info: 0
        case .warning: 1
        }
    }

    public init(_ diagnostic: ScoreDiagnostic) {
        self.init(
            severity: Self.severityValue(for: diagnostic.severity),
            code: diagnostic.code,
            message: diagnostic.message,
            location: diagnostic.location ?? "",
        )
    }
}

extension ScoreLoadResultWire {
    /// The failure shape: no handle, the error's own code and text, no diagnostics.
    ///
    /// Diagnostics are deliberately dropped on the failure path rather than partially reported. The
    /// parsers throw from wherever they got to, so whatever had accumulated describes the part of a
    /// document that never became a score — presenting it beside a hard failure invites a host to
    /// show "3 warnings" for a file that did not load at all.
    public init(failure error: SheetMusicError) {
        self.init(
            scoreHandle: 0,
            faultCode: error.code,
            faultMessage: error.developerDescription,
            diagnostics: [],
        )
    }

    /// The success shape.
    public init(scoreHandle: Int64, diagnostics: [ScoreDiagnostic]) {
        self.init(
            scoreHandle: scoreHandle,
            faultCode: "",
            faultMessage: "",
            diagnostics: diagnostics.map(ScoreDiagnosticWire.init),
        )
    }
}
