// Tests/SheetMusicPDFWriterTests/PDFPageSpaceTests.swift
@testable import SheetMusicPDFWriter
import Testing

/// The displayed page — y down from the top-left of the crop box as `/Rotate` turns it — in default user space.
struct PDFPageSpaceTests {
    /// A 200 × 100 box whose origin is not at zero, so a mapping that forgets the origin shows.
    static func space(_ rotation: Int) -> PDFPageSpace {
        PDFPageSpace(left: 10, bottom: 20, right: 210, top: 120, rotation: rotation)
    }

    @Test(arguments: [
        (0, 200.0, 100.0), (90, 100.0, 200.0), (180, 200.0, 100.0), (270, 100.0, 200.0), (-90, 100.0, 200.0),
    ])
    func `the displayed size turns with the page`(rotation: Int, width: Double, height: Double) {
        #expect(Self.space(rotation).displayedSize == PDFPageSize(width: width, height: height))
    }

    /// Each displayed corner lands on the user-space corner a viewer turns to that position.
    @Test func `the displayed top-left is the corner each rotation brings there`() {
        let origin = PDFPagePoint(x: 0, y: 0)
        #expect(Self.space(0).user(origin) == (10, 120))
        #expect(Self.space(90).user(origin) == (10, 20))
        #expect(Self.space(180).user(origin) == (210, 20))
        #expect(Self.space(270).user(origin) == (210, 120))
    }

    @Test func `a point moves along the displayed axes`() {
        let point = PDFPagePoint(x: 3, y: 5)
        #expect(Self.space(0).user(point) == (13, 115))
        #expect(Self.space(90).user(point) == (15, 23))
        #expect(Self.space(180).user(point) == (207, 25))
        #expect(Self.space(270).user(point) == (205, 117))
    }

    @Test func `a rotation off the quarter turns reads as none`() {
        #expect(PDFPageSpace(left: 0, bottom: 0, right: 1, top: 2, rotation: 45).rotation == 0)
    }
}
