import Foundation
import Testing
@testable import WireFormatKotlinEmitter
import WireFormatSchema

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
