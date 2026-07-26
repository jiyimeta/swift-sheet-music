import Foundation
import SheetMusicPDF
import Wirelet
#if canImport(CoreGraphics)
    import CoreGraphics
#endif

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

    public init(scoreHandle: Int64, geometryHandle: Int64, diagnostics: [PdfDiagnosticWire]) {
        self.scoreHandle = scoreHandle
        self.geometryHandle = geometryHandle
        self.diagnostics = diagnostics
    }
}

public enum PDFGeometryCodecs {
    /// Encode `rect` with its y flipped into top-left page space of `pageHeight`.
    public static func encodeTopLeft(_ rect: PDFElementRect, pageHeight: Double) -> Data {
        let flipped = rect.flipped(pageHeight: CGFloat(pageHeight))
        return PdfRectWire(
            pageIndex: Int32(flipped.pageIndex),
            x: Double(flipped.rect.origin.x),
            y: Double(flipped.rect.origin.y),
            width: Double(flipped.rect.size.width),
            height: Double(flipped.rect.size.height),
        ).encodeToData()
    }
}
