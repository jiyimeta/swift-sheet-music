import Testing
@testable import WireFormatKotlinEmitter
import WireFormatSchema

@Test func resolvesDefault() {
    let config = KotlinCodegenConfig(
        defaultModelPackage: "io.example.audio.model",
        defaultCodecPackage: "io.example.audio.serialization",
        nameTransform: .stripSuffix("Wire"),
    )
    let r = PackageResolver(config: config)

    let resolved = r.resolve(swiftName: "MetronomeBeatWire", target: .auto)

    #expect(resolved == .emit(
        modelPackage: "io.example.audio.model",
        codecPackage: "io.example.audio.serialization",
        serializationPackage: "io.example.audio.serialization",
        kotlinName: "MetronomeBeat",
    ))
}

@Test func ruleOverridesDefault() {
    let config = KotlinCodegenConfig(
        defaultModelPackage: "io.example.audio.model",
        defaultCodecPackage: "io.example.audio.serialization",
        nameTransform: .stripSuffix("Wire"),
        rules: [Rule(
            pattern: "Score*",
            modelPackage: "io.example.score",
            codecPackage: "io.example.score",
        )],
    )
    let r = PackageResolver(config: config)

    let resolved = r.resolve(swiftName: "ScoreMetadataWire", target: .auto)

    #expect(resolved == .emit(
        modelPackage: "io.example.score",
        codecPackage: "io.example.score",
        serializationPackage: "io.example.audio.serialization",
        kotlinName: "ScoreMetadata",
    ))
}

@Test func explicitTargetSkipsConfig() {
    let config = KotlinCodegenConfig(
        defaultModelPackage: "io.example.audio.model",
        defaultCodecPackage: "io.example.audio.serialization",
    )
    let r = PackageResolver(config: config)

    let resolved = r.resolve(swiftName: "FooWire", target: .explicit("io.other.Foo"))

    #expect(resolved == .emit(
        modelPackage: "io.other",
        codecPackage: "io.other",
        serializationPackage: "io.example.audio.serialization",
        kotlinName: "Foo",
    ))
}

@Test func skipTargetEmitsNothing() {
    let config = KotlinCodegenConfig(
        defaultModelPackage: "io.example.audio.model",
        defaultCodecPackage: "io.example.audio.serialization",
    )
    let r = PackageResolver(config: config)

    let resolved = r.resolve(swiftName: "FooWire", target: .skip)

    #expect(resolved == .skip)
}
