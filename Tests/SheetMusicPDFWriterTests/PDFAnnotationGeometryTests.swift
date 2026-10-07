import Foundation
@testable import SheetMusicPDFWriter
import Testing

/// Public annotation geometry must never trap in the fixed-point content serializer.
struct PDFAnnotationGeometryTests {
    @Test(arguments: [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, 1e16, -1e16])
    func `unrepresentable ink coordinates are omitted in both writers`(coordinate: Double) throws {
        let ink = PDFPageAnnotationTests.ink(x: coordinate)
        #expect(try PDFPageAnnotationTests.write([0: [ink]]) == PDFPageAnnotationTests.write())
        let original = PDFFixtures.make([.init()])
        #expect(try PDFIncrementalAnnotator.append([0: [ink]], to: original) == original)
    }

    @Test func `invalid widths colors opacity and clip controls are omitted`() throws {
        guard case let .ink(base) = PDFPageAnnotationTests.ink() else { return }
        var width = base, color = base, opacity = base, clip = base
        width.width = .greatestFiniteMagnitude
        color.color.red = .nan
        opacity.opacity = .infinity
        clip.clip = PDFClipPath(elements: [
            .move(PDFPagePoint(x: 0, y: 0)),
            .quad(PDFPagePoint(x: 1e16, y: 0), PDFPagePoint(x: 10, y: 10)), .close,
        ], evenOdd: false)
        #expect(try PDFPageAnnotationTests.write([0: [.ink(width), .ink(color), .ink(opacity), .ink(clip)]])
            == PDFPageAnnotationTests.write())
    }

    @Test func `computed highlight corners and transformed coordinates are validated`() throws {
        let highlight = PDFPageAnnotation.highlight(PDFHighlightAnnotation(
            rect: PDFPageRect(x: 8e15, y: 0, width: 8e15, height: 10), color: PDFPageAnnotationTests.red,
        ))
        #expect(try PDFPageAnnotationTests.write([0: [highlight]]) == PDFPageAnnotationTests.write())
        let original = PDFFixtures.make([.init(mediaBox: "[0 0 100000000000000000000 100000000000000000000]")])
        #expect(try PDFIncrementalAnnotator.append([0: [PDFPageAnnotationTests.ink()]], to: original) == original)
    }

    @Test func `invalid additions do not discard valid neighboring annotations`() throws {
        let original = PDFFixtures.make([.init()])
        let appended = try PDFIncrementalAnnotator.append(
            [0: [PDFPageAnnotationTests.ink(x: .nan), PDFPageAnnotationTests.ink()]], to: original,
        )
        let document = try PDFSourceDocument(appended)
        #expect(try PDFIncrementalAnnotatorTests.subtypes(#require(document.pages().first), in: document)
            == [.name("Ink")])
    }
}
