import Foundation
import Testing
@testable import WireFormatKotlinEmitter
import WireFormatSchema

@Test func emitsChoiceCodec() throws {
    let schema = Schema(types: [
        .choice(WireChoice(
            name: "ScoreCursorWire",
            cases: [
                WireChoiceCase(name: "item", payload: [
                    PayloadField(label: nil, typeText: "ScoreItemIDWire"),
                ]),
                WireChoiceCase(name: "beat", payload: [
                    PayloadField(label: "measureIndex", typeText: "Int32"),
                    PayloadField(label: "tickInMeasure", typeText: "Int32"),
                ]),
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
        forResource: "ScoreCursorCodec.expected",
        withExtension: "kt",
        subdirectory: "Fixtures",
    ))
    let expected = try String(contentsOf: expectedURL, encoding: .utf8)
    #expect(files[0].content == expected)
}

/// Regression: a payload type like `Outer.Inner` (Swift nested-type ref)
/// must produce `InnerCodec` and `import …model.Inner` — not
/// `Outer.InnerCodec` / `import …model.Outer.Inner`, which would not
/// compile since codecs and model classes are emitted at top level.
@Test func emitsCodecForNestedTypeReferenceInPayload() throws {
    let schema = Schema(types: [
        .choice(WireChoice(
            name: "Sample",
            cases: [
                WireChoiceCase(name: "withNestedRef", payload: [
                    PayloadField(label: "id", typeText: "Outer.Inner"),
                ]),
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
    #expect(content.contains("import io.example.audio.model.Inner"))
    #expect(!content.contains("Outer.Inner"))
    #expect(content.contains("InnerCodec.encodePayload"))
    #expect(content.contains("InnerCodec.decodePayload"))
}
