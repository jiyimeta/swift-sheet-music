import Foundation
import Testing
@testable import WireFormatKotlinEmitter
import WireFormatSchema

@Test func emitsStructWithArrayField() throws {
    let schema = Schema(types: [
        .struct(WireStruct(
            name: "SMuFLMetricsWire",
            fields: [
                WireField(name: "magic", typeText: "UInt32"),
                WireField(name: "version", typeText: "UInt32"),
                WireField(name: "referenceSize", typeText: "Double"),
                WireField(name: "entries", typeText: "[SMuFLMetricsEntryWire]"),
            ],
            kotlinTarget: .auto,
        )),
    ])
    let config = KotlinCodegenConfig(
        defaultModelPackage: "io.github.jiyimeta.sheetmusic.audio.model",
        defaultCodecPackage: "io.github.jiyimeta.sheetmusic.audio.serialization",
        nameTransform: .stripSuffix("Wire"),
        rules: [
            Rule(
                pattern: "SMuFL*",
                modelPackage: "io.github.jiyimeta.sheetmusic",
                codecPackage: "io.github.jiyimeta.sheetmusic",
            ),
        ],
    )

    let files = try KotlinEmitter(config: config).emit(schema: schema)

    #expect(files.count == 1)
    let expectedURL = try #require(Bundle.module.url(
        forResource: "SMuFLMetricsCodec.expected",
        withExtension: "kt",
        subdirectory: "Fixtures",
    ))
    let expected = try String(contentsOf: expectedURL, encoding: .utf8)
    #expect(files[0].content == expected)
    #expect(files[0].relativePath == "io/github/jiyimeta/sheetmusic/SMuFLMetricsCodec.kt")
}

@Test func emitsStructCodec() throws {
    let schema = Schema(types: [
        .struct(WireStruct(
            name: "PointWire",
            fields: [
                WireField(name: "x", typeText: "Int32"),
                WireField(name: "y", typeText: "Int32"),
            ],
            kotlinTarget: .auto,
        )),
    ])
    let config = KotlinCodegenConfig(
        defaultModelPackage: "io.example.audio.model",
        defaultCodecPackage: "io.example.audio.serialization",
        nameTransform: .stripSuffix("Wire"),
    )

    let files = try KotlinEmitter(config: config).emit(schema: schema)

    #expect(files.count == 1)
    let expectedURL = try #require(Bundle.module.url(
        forResource: "PointCodec.expected",
        withExtension: "kt",
        subdirectory: "Fixtures",
    ))
    let expected = try String(contentsOf: expectedURL, encoding: .utf8)
    #expect(files[0].content == expected)
    #expect(files[0].relativePath == "io/example/audio/serialization/PointCodec.kt")
}
