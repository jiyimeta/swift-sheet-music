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

@Test func parsesChoiceEnum() throws {
    let url = try #require(Bundle.module.url(
        forResource: "ChoiceEnum",
        withExtension: "swift",
        subdirectory: "Fixtures",
    ))
    let source = try String(contentsOf: url, encoding: .utf8)

    let schema = SchemaParser.parse(source: source, fileName: "ChoiceEnum.swift")

    #expect(schema.types.count == 1)
    guard case let .choice(c) = schema.types[0] else {
        Issue.record("Expected choice, got \(schema.types[0])")
        return
    }
    #expect(c.name == "ScoreCursorWire")
    #expect(c.cases == [
        WireChoiceCase(name: "item", payloadTypes: ["ScoreItemIDWire"]),
        WireChoiceCase(name: "beat", payloadTypes: ["Int32", "Int32"]),
    ])
}

@Test func parsesRawEnum() throws {
    let url = try #require(Bundle.module.url(
        forResource: "RawEnum",
        withExtension: "swift",
        subdirectory: "Fixtures",
    ))
    let source = try String(contentsOf: url, encoding: .utf8)

    let schema = SchemaParser.parse(source: source, fileName: "RawEnum.swift")

    #expect(schema.types.count == 1)
    guard case let .rawEnum(e) = schema.types[0] else {
        Issue.record("Expected rawEnum, got \(schema.types[0])")
        return
    }
    #expect(e.name == "GMInstrumentFamilyWire")
    #expect(e.cases == ["piano", "chromaticPercussion", "organ"])
}
