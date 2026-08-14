import SheetMusicFoundation
import Wirelet

/// One rectangle on one PDF page, in **top-left origin, y-down** page space — the convention the Reader
/// lays PDF pages out in on both platforms. The Swift side flips; Kotlin never converts.
@WireFormat
public struct PdfRectWire: Equatable {
    public let pageIndex: Int32
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(pageIndex: Int32, x: Double, y: Double, width: Double, height: Double) {
        self.pageIndex = pageIndex
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// MediaBox sizes as the importer saw them, indexed positionally by page. The caller scales geometry
/// rects by (rendered page width in px / `widths[page]`), so a renderer that disagrees about the box
/// can be detected rather than silently mis-placing the cursor.
///
/// Two cases mean "unknown — do not scale, use the geometry rect as-is": a page whose size the importer
/// never recorded encodes as `0` at that index (scaling by it would divide by zero); and, because a
/// trailing run of unrecorded pages is simply not appended, `widths`/`heights` can be SHORTER than the
/// document's actual rendered page count, so a page index at or past `widths.count` also means unknown
/// rather than an error. A caller must check both before indexing or dividing.
@WireFormat
public struct PdfPageSizesWire: Equatable {
    public let widths: [Double]
    public let heights: [Double]

    public init(widths: [Double], heights: [Double]) {
        self.widths = widths
        self.heights = heights
    }
}

/// One best-effort importer diagnostic. `severity`: 0 = info, 1 = warning.
@WireFormat
public struct PdfDiagnosticWire: Equatable {
    public let severity: Int32
    public let location: String
    public let message: String

    public init(severity: Int32, location: String, message: String) {
        self.severity = severity
        self.location = location
        self.message = message
    }
}

/// Result of a PDF parse: a score handle for playback, a geometry handle for cursor/hit-test lookups,
/// and the diagnostics collected during the parse.
@WireFormat
public struct PdfParseResultWire: Equatable {
    public let scoreHandle: Int64
    public let geometryHandle: Int64
    public let diagnostics: [PdfDiagnosticWire]
    /// Number of chord/rest elements the importer actually reconstructed, across every staff and voice.
    ///
    /// Reported as a plain fact, not a verdict: a PDF outside the importer's scope (a Chrome "print to PDF",
    /// a scan) still yields staff lines and measure cells, so a caller that only checks "did the parse throw"
    /// sees a structurally valid `Score` with nothing in it and offers the user a silent transport. The
    /// consumer decides what count is worth playing — this side only counts.
    public let playableElementCount: Int32

    public init(
        scoreHandle: Int64,
        geometryHandle: Int64,
        diagnostics: [PdfDiagnosticWire],
        playableElementCount: Int32 = 0,
    ) {
        self.scoreHandle = scoreHandle
        self.geometryHandle = geometryHandle
        self.diagnostics = diagnostics
        self.playableElementCount = playableElementCount
    }
}
