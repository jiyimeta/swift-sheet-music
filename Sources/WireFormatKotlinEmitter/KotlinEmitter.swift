import WireFormatSchema

public struct KotlinFile: Equatable, Sendable {
    public var relativePath: String // e.g. "io/example/audio/serialization/FooCodec.kt"
    public var content: String
    public init(relativePath: String, content: String) {
        self.relativePath = relativePath
        self.content = content
    }
}

public enum KotlinEmitterError: Error, Equatable {
    case unsupportedType(String)
}

public struct KotlinEmitter: Sendable {
    public let config: KotlinCodegenConfig
    private let resolver: PackageResolver

    public init(config: KotlinCodegenConfig) {
        self.config = config
        resolver = PackageResolver(config: config)
    }

    public func emit(schema: Schema) throws -> [KotlinFile] {
        var files: [KotlinFile] = []
        for type in schema.types {
            let resolved = resolver.resolve(swiftName: type.name, target: type.kotlinTarget)
            guard case let .emit(modelPkg, codecPkg, kotlinName) = resolved else { continue }
            switch type {
            case let .struct(s):
                // Placeholder: real emission implemented in Task 8 (StructEmitter).
                _ = (s, modelPkg, codecPkg, kotlinName)
                throw KotlinEmitterError.unsupportedType(type.name)
            case let .choice(c):
                // Placeholder: real emission implemented in Task 9 (ChoiceEmitter).
                _ = (c, modelPkg, codecPkg, kotlinName)
                throw KotlinEmitterError.unsupportedType(type.name)
            case let .rawEnum(e):
                // Placeholder: real emission implemented in Task 10 (EnumEmitter).
                _ = (e, modelPkg, codecPkg, kotlinName)
                throw KotlinEmitterError.unsupportedType(type.name)
            }
        }
        return files
    }
}
