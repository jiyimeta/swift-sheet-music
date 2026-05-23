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
                files.append(StructEmitter.emit(
                    s,
                    kotlinName: kotlinName,
                    modelPackage: modelPkg,
                    codecPackage: codecPkg,
                    nameTransform: config.nameTransform,
                ))
            case let .choice(c):
                files.append(ChoiceEmitter.emit(
                    c,
                    kotlinName: kotlinName,
                    modelPackage: modelPkg,
                    codecPackage: codecPkg,
                    nameTransform: config.nameTransform,
                ))
            case let .rawEnum(e):
                files.append(EnumEmitter.emit(
                    e,
                    kotlinName: kotlinName,
                    modelPackage: modelPkg,
                    codecPackage: codecPkg,
                ))
            }
        }
        return files
    }
}
