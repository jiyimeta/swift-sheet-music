import WireFormatSchema

public enum ResolvedTarget: Equatable, Sendable {
    case skip
    case emit(
        modelPackage: String,
        codecPackage: String,
        serializationPackage: String,
        kotlinName: String,
    )
}

public struct PackageResolver: Sendable {
    public let config: KotlinCodegenConfig
    public init(config: KotlinCodegenConfig) {
        self.config = config
    }

    public func resolve(swiftName: String, target: KotlinTarget) -> ResolvedTarget {
        let fallbackSerialization = config.defaultSerializationPackage ?? config.defaultCodecPackage
        switch target {
        case .skip:
            return .skip
        case let .explicit(fqn):
            let (pkg, name) = splitFQN(fqn)
            return .emit(
                modelPackage: pkg,
                codecPackage: pkg,
                serializationPackage: fallbackSerialization,
                kotlinName: name,
            )
        case .auto:
            let kotlinName = config.nameTransform.apply(to: swiftName)
            for rule in config.rules where matches(pattern: rule.pattern, name: swiftName) {
                let codecPkg = rule.codecPackage ?? config.defaultCodecPackage
                let serPkg = rule.serializationPackage ?? fallbackSerialization
                return .emit(
                    modelPackage: rule.modelPackage ?? config.defaultModelPackage,
                    codecPackage: codecPkg,
                    serializationPackage: serPkg,
                    kotlinName: kotlinName,
                )
            }
            return .emit(
                modelPackage: config.defaultModelPackage,
                codecPackage: config.defaultCodecPackage,
                serializationPackage: fallbackSerialization,
                kotlinName: kotlinName,
            )
        }
    }

    /// Simple prefix-glob match: `"Score*"` matches names starting with `"Score"`,
    /// `"*"` matches anything, plain `"Foo"` is an exact match. Only one `*`
    /// supported and only as a trailing wildcard.
    private func matches(pattern: String, name: String) -> Bool {
        if pattern == "*" { return true }
        if pattern.hasSuffix("*") {
            let prefix = pattern.dropLast()
            return name.hasPrefix(prefix)
        }
        return pattern == name
    }

    private func splitFQN(_ fqn: String) -> (package: String, name: String) {
        guard let lastDot = fqn.lastIndex(of: ".") else { return ("", fqn) }
        return (String(fqn[..<lastDot]), String(fqn[fqn.index(after: lastDot)...]))
    }
}
