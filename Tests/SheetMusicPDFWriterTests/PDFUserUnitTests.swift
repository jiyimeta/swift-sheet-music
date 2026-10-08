import Foundation
@testable import SheetMusicPDFWriter
import Testing

struct PDFUserUnitTests {
    @Test(arguments: [PDFFixtures.Shape.classic, .objectStreams])
    func `unit1 incremental output stays byte identical`(shape: PDFFixtures.Shape) throws {
        let original = PDFFixtures.make([.init()], shape: shape)
        let file = try PDFIncrementalAnnotator.append([0: [PDFIncrementalAnnotatorTests.ink]], to: original)
        let baseline: UInt64 = shape == .classic ? 9_401_802_587_389_181_449 : 5_441_107_980_154_862_124
        #expect(PDFPageAnnotationTests.fnv1a(file) == baseline)
    }

    @Test func `physical points scale ink appearance mask and border into default user space`() throws {
        let original = PDFFixtures.make([.init(mediaBox: "[0 0 300 400]", extra: " /UserUnit 2")])
        #expect(try PDFIncrementalAnnotator.pageSizes(of: original) == [PDFPageSize(width: 600, height: 800)])
        let clip = PDFClipPath(elements: [
            .move(PDFPagePoint(x: 20, y: 30)), .line(PDFPagePoint(x: 30, y: 30)),
            .line(PDFPagePoint(x: 30, y: 40)), .close,
        ], evenOdd: true)
        guard case var .ink(ink) = PDFPageAnnotationTests.ink(x: 20, y: 30, clip: clip) else { return }
        ink.width = 4
        let file = try PDFIncrementalAnnotator.append([0: [.ink(ink)]], to: original)
        #expect(file.prefix(original.count) == original)
        let text = PDFPageAnnotationTests.text(file)
        #expect(text.contains("/InkList [[10 385 15 385]]"))
        #expect(text.contains("/BS << /W 2 >>")) // Two default units remain four physical points.
        #expect(text.contains("/Rect [9 379 16 386]"))
        #expect(text.contains("/BBox [9 379 16 386]"))
        let appearance = try #require(PDFPageAnnotationTests.appearances(in: file).first)
        #expect(appearance.contains("10 385 m\n15 385 l\n15 380 l\nh\nW* n"))
        #expect(appearance.contains("10 385 m\n15 385 l\n15 380 l\n10 380 l\nh\nf"))
    }

    @Test func `physical points respect rotation and an offset crop box`() throws {
        let original = PDFFixtures.make([.init(
            extra: " /UserUnit 2 /Rotate 90 /CropBox [10 20 210 120]",
        )])
        #expect(try PDFIncrementalAnnotator.pageSizes(of: original) == [PDFPageSize(width: 200, height: 400)])
        let highlight = PDFPageAnnotation.highlight(PDFHighlightAnnotation(
            rect: PDFPageRect(x: 20, y: 30, width: 10, height: 20), color: PDFPageAnnotationTests.red,
        ))
        let file = try PDFIncrementalAnnotator.append([0: [PDFIncrementalAnnotatorTests.ink, highlight]], to: original)
        let text = PDFPageAnnotationTests.text(file)
        #expect(text.contains("/InkList [[25 30 25 35]]"))
        #expect(text.contains("/QuadPoints [25 30 25 35 35 30 35 35]"))
    }

    @Test func `large UserUnit preserves small marks at physical point precision`() throws {
        let original = PDFFixtures.make([.init(mediaBox: "[0 0 0.008 0.011]", extra: " /UserUnit 75000")])
        let clip = PDFClipPath(elements: [
            .move(PDFPagePoint(x: 20, y: 30)), .line(PDFPagePoint(x: 30, y: 30)),
            .line(PDFPagePoint(x: 30, y: 40)), .close,
        ], evenOdd: false)
        guard case var .ink(ink) = PDFPageAnnotationTests.ink(x: 20, y: 30, clip: clip) else { return }
        ink.width = 4
        let file = try PDFIncrementalAnnotator.append([0: [.ink(ink)]], to: original)
        let document = try PDFSourceDocument(file)
        let page = try #require(document.pages().first)
        let reference = try #require(page.dictionary["Annots"]?.arrayValue?.first)
        let annotation = try #require(document.resolve(reference).dictionaryValue)
        let width = try #require(annotation["BS"]?.dictionaryValue?["W"]?.doubleValue)
        #expect(abs(width * 75000 - 4) < 0.000001)
        let line = try #require(annotation["InkList"]?.arrayValue?.first?.arrayValue)
        let physicalLine = try line.map { try #require($0.doubleValue) * 75000 }
        for (actual, expected) in zip(physicalLine, [20.0, 795, 30, 795]) {
            #expect(abs(actual - expected) < 0.000001)
        }
        let rect = try #require(annotation["Rect"]?.arrayValue)
        for (coordinate, expected) in zip(rect, [18.0, 783, 32, 797]) {
            #expect(try abs(#require(coordinate.doubleValue) * 75000 - expected) < 0.000001)
        }
        let appearance = try #require(PDFPageAnnotationTests.appearances(in: file).first)
        let moves = appearance.split(separator: "\n").filter { $0.hasSuffix(" m") }
        #expect(moves.count == 2) // Both the clip and the filled outline must keep their sub-point raw coordinates.
        for move in moves {
            let values = move.split(separator: " ")
            #expect(try abs(#require(Double(values[0])) * 75000 - 20) < 0.000001)
            #expect(try abs(#require(Double(values[1])) * 75000 - 795) < 0.000001)
        }
    }

    @Test func `userUnit resolves per page and is not inherited from Pages`() throws {
        let original = PDFFixtures.make([
            .init(mediaBox: "[0 0 300 400]", extra: " /UserUnit 7 0 R"),
            .init(mediaBox: "[0 0 300 400]"),
        ])
        let unit = PDFFixtures.updated(original, redefining: 7, as: "2")
        let parent = PDFFixtures.updated(
            unit,
            redefining: 2,
            as:
            "<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 /UserUnit 3 >>",
        )
        #expect(try PDFIncrementalAnnotator.pageSizes(of: parent) == [
            PDFPageSize(width: 600, height: 800), PDFPageSize(width: 300, height: 400),
        ])
    }

    @Test(arguments: ["0", "-2", "(2)", "null"])
    func `invalid UserUnit is refused`(value: String) {
        let original = PDFFixtures.make([.init(extra: " /UserUnit \(value)")])
        #expect(throws: PDFAppendError.unreadable) { try PDFIncrementalAnnotator.pageSizes(of: original) }
    }

    @Test func `overflowing physical page dimensions are refused`() {
        let huge = "1" + String(repeating: "0", count: 308)
        let original = PDFFixtures.make([.init(mediaBox: "[0 0 \(huge) 400]", extra: " /UserUnit 2")])
        #expect(throws: PDFAppendError.unreadable) { try PDFIncrementalAnnotator.pageSizes(of: original) }
    }

    @Test func `explicit Unit1 and default Unit1 append identical bytes`() throws {
        let original = PDFFixtures.make([.init()])
        let source = try PDFSourceDocument(original)
        let defaultSpace = try #require(source.pages().first).space
        let explicit = PDFFixtures.make([.init(extra: " /UserUnit 1")])
        let explicitSpace = try #require(PDFSourceDocument(explicit).pages().first).space
        let first = PDFIncrementalWriter(original: original, nextNumber: 5)
        let second = PDFIncrementalWriter(original: original, nextNumber: 5)
        _ = try PDFAnnotationObjects.write([PDFIncrementalAnnotatorTests.ink], in: defaultSpace, into: first)
        _ = try PDFAnnotationObjects.write([PDFIncrementalAnnotatorTests.ink], in: explicitSpace, into: second)
        for stream in [false, true] {
            #expect(try first.finish(trailer: source.trailer, previous: source.startXRef, asStream: stream)
                == second.finish(trailer: source.trailer, previous: source.startXRef, asStream: stream))
        }
    }
}
