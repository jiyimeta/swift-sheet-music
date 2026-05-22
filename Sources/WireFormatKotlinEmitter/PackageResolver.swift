import WireFormatSchema

public enum ResolvedTarget: Equatable, Sendable {
    case skip
    case emit(modelPackage: String, codecPackage: String, kotlinName: String)
}

public struct PackageResolver: Sendable {
    public let config: KotlinCodegenConfig
    public init(config: KotlinCodegenConfig) {
        self.config = config
    }

    public func resolve(swiftName: String, target: KotlinTarget) -> ResolvedTarget {
        switch target {
        case .skip:
            return .skip
        case let .explicit(fqn):
            let (pkg, name) = splitFQN(fqn)
            return .emit(modelPackage: pkg, codecPackage: pkg, kotlinName: name)
        case .auto:
            let kotlinName = config.nameTransform.apply(to: swiftName)
            for rule in config.rules where matches(pattern: rule.pattern, name: swiftName) {
                return .emit(
                    modelPackage: rule.modelPackage ?? config.defaultModelPackage,
                    codecPackage: rule.codecPackage ?? config.defaultCodecPackage,
                    kotlinName: kotlinName,
                )
            }
            return .emit(
                modelPackage: config.defaultModelPackage,
                codecPackage: config.defaultCodecPackage,
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
