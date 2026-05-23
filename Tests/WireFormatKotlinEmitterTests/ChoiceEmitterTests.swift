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
