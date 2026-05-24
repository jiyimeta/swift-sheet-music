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

/// Regression: a field whose Swift type is a nested ref (`Outer.Inner`)
/// must produce `InnerCodec.encodePayload(...)`, not `Outer.InnerCodec…`.
@Test func emitsStructCodecForNestedTypeReferenceField() throws {
    let schema = Schema(types: [
        .struct(WireStruct(
            name: "Sample",
            fields: [
                WireField(name: "scalar", typeText: "Outer.Inner"),
                WireField(name: "items", typeText: "[Outer.Inner]"),
            ],
            kotlinTarget: .auto,
        )),
    ])
    let config = KotlinCodegenConfig(
        defaultModelPackage: "io.example.audio.model",
        defaultCodecPackage: "io.example.audio.serialization",
    )

    let files = try KotlinEmitter(config: config).emit(schema: schema)

    #expect(files.count == 1)
    let content = files[0].content
    #expect(!content.contains("Outer.Inner"))
    #expect(content.contains("InnerCodec.encodePayload"))
    #expect(content.contains("InnerCodec.decodePayload"))
    #expect(content.contains("ArrayList<Inner>"))
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
