import Foundation
import SheetMusicCore
import SheetMusicPDF
#if canImport(CoreGraphics)
    import CoreGraphics
#endif

// PDF geometry JNI bridge. A PDF parse yields two long-lived values: the `Score` (which goes into the
// existing score table so every playback bridge works unchanged) and the `PDFScoreGeometry` side-car,
// kept here together with the score it was produced from — `cursorRect` needs both.
//
// Every rect crossing this boundary is flipped to top-left page space by `PDFGeometryCodecs.encodeTopLeft`,
// and every point arriving is flipped back, so the Kotlin caller works in one convention and never
// re-implements the flip.

struct PDFGeometryEntry {
    let score: Score
    let geometry: PDFScoreGeometry
}

let pdfGeometryTable = HandleTable<PDFGeometryEntry>()

/// JNI entry point for `SheetMusicJNI.nativeLoadScoreWithGeometryFromPDF(...)`. Parses a
/// MuseScore-exported vector PDF into a `Score` plus its geometry side-car and returns a
/// `PdfParseResultWire`. Empty `Data` on empty input or parse failure. The caller must release BOTH
/// handles — `nativeReleaseScore` and `nativeReleasePdfGeometry`.
public func nativeLoadScoreWithGeometryFromPDF(bytes: Data) -> Data {
    guard !bytes.isEmpty else { return Data() }
    let collector = PDFDiagnosticsCollector()
    var options = PDFImportOptions()
    options.diagnostics = { collector.append($0) }
    do {
        let (score, geometry) = try PDFImporter.parseWithGeometryUsingSwiftReader(
            pdfData: bytes, options: options,
        )
        let scoreHandle = scoreTable.insert(score)
        let geometryHandle = pdfGeometryTable.insert(
            PDFGeometryEntry(score: score, geometry: geometry),
        )
        return PdfParseResultWire(
            scoreHandle: scoreHandle,
            geometryHandle: geometryHandle,
            diagnostics: collector.snapshot(),
            playableElementCount: Int32(clamping: playableElementCount(of: score)),
        ).encodeToData()
    } catch {
        return Data()
    }
}

/// Full-height cursor bar for `cursorBytes` (a `ScoreCursorWire`) on the original PDF, in top-left page
/// space. Empty `Data` when the handle is unknown, the cursor doesn't decode, or the column can't be located.
public func nativePdfCursorRect(geometryHandle: Int64, cursorBytes: Data) -> Data {
    guard let entry = pdfGeometryTable.value(for: geometryHandle),
          !cursorBytes.isEmpty,
          let cursor = try? ScoreCursorCodec.decode(cursorBytes),
          let rect = entry.geometry.cursorRect(for: cursor, in: entry.score),
          let pageSize = entry.geometry.pageSizes[rect.pageIndex]
    else { return Data() }
    return PDFGeometryCodecs.encodeTopLeft(rect, pageHeight: Double(pageSize.height))
}

/// Resolve a tap at (`x`, `y`) in top-left page space on `pageIndex` to a `ScoreCursorWire` the playback
/// bridges accept. Empty `Data` when the handle is unknown or nothing musical is near the tap.
public func nativePdfHitTest(geometryHandle: Int64, pageIndex: Int32, x: Double, y: Double) -> Data {
    guard let entry = pdfGeometryTable.value(for: geometryHandle),
          let pageSize = entry.geometry.pageSizes[Int(pageIndex)]
    else { return Data() }
    // Incoming point is top-left/y-down; hitTest works in PDF user space (y-up).
    let point = CGPoint(x: CGFloat(x), y: pageSize.height - CGFloat(y))
    guard let item = entry.geometry.hitTest(pageIndex: Int(pageIndex), point: point) else { return Data() }
    return ScoreCursorCodec.encode(.item(item))
}

/// MediaBox sizes indexed positionally by page. Empty `Data` for an unknown handle.
public func nativePdfPageSizes(geometryHandle: Int64) -> Data {
    guard let entry = pdfGeometryTable.value(for: geometryHandle) else { return Data() }
    let pageCount = (entry.geometry.pageSizes.keys.max() ?? -1) + 1
    guard pageCount > 0 else { return Data() }
    var widths = [Double](repeating: 0, count: pageCount)
    var heights = [Double](repeating: 0, count: pageCount)
    for (page, size) in entry.geometry.pageSizes where page >= 0 && page < pageCount {
        widths[page] = Double(size.width)
        heights[page] = Double(size.height)
    }
    return PdfPageSizesWire(widths: widths, heights: heights).encodeToData()
}

/// Release a geometry handle. Unknown handles are a no-op.
public func nativeReleasePdfGeometry(handle: Int64) {
    pdfGeometryTable.release(handle)
}

/// Count the elements the importer reconstructed that could actually sound: chords carrying at least one
/// note, across every staff and voice.
///
/// A PDF the importer cannot read — a Chrome "print to PDF", a scan — still yields staff lines and measure
/// cells, so the resulting `Score` is structurally valid and empty. This is the fact a host needs to tell
/// that apart from a real parse; the host, not this function, decides what count is worth playing.
///
/// Counting `voice.elements` wholesale would be wrong, and quietly so: a voice also carries clef, key and
/// time-signature elements, and the importer emits those from a state machine that never inspects a
/// notehead. A page whose clef classifies but whose noteheads do not would then report a non-zero count and
/// put the host right back on "playable transport, one second, silence" — the exact symptom this count
/// exists to prevent. Rests are excluded for the same reason: an all-rest decode has nothing to sound.
func playableElementCount(of score: Score) -> Int {
    var count = 0
    for (_, staff) in score.allStaves {
        for measure in staff.measures {
            for voice in measure.voices {
                for element in voice.elements {
                    if case let .chord(chord) = element, !chord.notes.isEmpty { count += 1 }
                }
            }
        }
    }
    return count
}

/// Thread-safe sink for the importer's `@Sendable` diagnostics callback, mapping to the wire type.
private final class PDFDiagnosticsCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [PdfDiagnosticWire] = []

    func append(_ diagnostic: PDFImportDiagnostic) {
        let severity: Int32 = switch diagnostic.severity {
        case .warning: 1
        default: 0
        }
        lock.lock()
        items.append(PdfDiagnosticWire(
            severity: severity, location: diagnostic.location, message: diagnostic.message,
        ))
        lock.unlock()
    }

    func snapshot() -> [PdfDiagnosticWire] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}
