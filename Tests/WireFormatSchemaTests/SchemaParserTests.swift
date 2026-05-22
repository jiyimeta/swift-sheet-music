import Foundation
import Testing
@testable import WireFormatSchema

@Test func parsesSimpleStruct() throws {
    let fixtureURL = try #require(Bundle.module.url(
        forResource: "SimpleStruct",
        withExtension: "swift",
        subdirectory: "Fixtures",
    ))
    let source = try String(contentsOf: fixtureURL, encoding: .utf8)

    let schema = SchemaParser.parse(source: source, fileName: "SimpleStruct.swift")

    #expect(schema.types.count == 1)
    guard case let .struct(s) = schema.types[0] else {
        Issue.record("Expected struct, got \(schema.types[0])")
        return
    }
    #expect(s.name == "PointWire")
    #expect(s.fields == [
        WireField(name: "x", typeText: "Int32"),
        WireField(name: "y", typeText: "Int32"),
    ])
    #expect(s.kotlinTarget == .auto)
}
