import Foundation
@testable import SheetMusicPDFWriter
import Testing

struct PDFSourceNumberTests {
    @Test func `real serialization keeps existing dictionary precision`() {
        let value = PDFSourceValue.real(1.2345678901234567)
        var parser = PDFSourceParser(Array(value.serialized.utf8))
        #expect(parser.parseValue() == value)
    }

    @Test(arguments: [1e300, -1e300, Double.leastNonzeroMagnitude, Double.greatestFiniteMagnitude, 1.0, -0.0])
    func `every finite real has a round trip decimal token`(number: Double) {
        let value = PDFSourceValue.real(number)
        let token = value.serialized
        #expect(!token.lowercased().contains("e"))
        var parser = PDFSourceParser(Array(token.utf8))
        #expect(parser.parseValue() == value)
    }

    @Test(arguments: ["nan", "inf", "-inf", "1e999"])
    func `nonfinite real tokens are rejected`(token: String) {
        var parser = PDFSourceParser(Array(token.utf8))
        #expect(parser.parseValue() == nil)
    }
}
