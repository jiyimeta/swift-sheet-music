import Foundation

public struct KotlinCodegenConfig: Codable, Sendable, Equatable {
    public var defaultModelPackage: String
    public var defaultCodecPackage: String
    /// Package containing `BinaryReader` / `BinaryWriter` for codecs that
    /// live in `defaultCodecPackage`. Defaults to `defaultCodecPackage` when
    /// omitted (the serialization helpers live alongside the generated codecs).
    public var defaultSerializationPackage: String?
    public var nameTransform: NameTransform
    public var rules: [Rule]

    public init(
        defaultModelPackage: String,
        defaultCodecPackage: String,
        defaultSerializationPackage: String? = nil,
        nameTransform: NameTransform = .identity,
        rules: [Rule] = [],
    ) {
        self.defaultModelPackage = defaultModelPackage
        self.defaultCodecPackage = defaultCodecPackage
        self.defaultSerializationPackage = defaultSerializationPackage
        self.nameTransform = nameTransform
        self.rules = rules
    }
}

public struct Rule: Codable, Sendable, Equatable {
    public var pattern: String
    public var modelPackage: String?
    public var codecPackage: String?
    /// Package containing `BinaryReader` / `BinaryWriter` for codecs matched
    /// by this rule. When `nil`, the emitter falls back to
    /// `KotlinCodegenConfig.defaultSerializationPackage` (or
    /// `defaultCodecPackage` if that is also unset).
    public var serializationPackage: String?
    public init(
        pattern: String,
        modelPackage: String? = nil,
        codecPackage: String? = nil,
        serializationPackage: String? = nil,
    ) {
        self.pattern = pattern
        self.modelPackage = modelPackage
        self.codecPackage = codecPackage
        self.serializationPackage = serializationPackage
    }
}

public enum NameTransform: Codable, Sendable, Equatable {
    case identity
    case stripSuffix(String)

    public func apply(to name: String) -> String {
        switch self {
        case .identity: return name
        case let .stripSuffix(suffix):
            return name.hasSuffix(suffix) ? String(name.dropLast(suffix.count)) : name
        }
    }

    /// Encodes to `{"identity":true}` or `{"stripSuffix":"Wire"}` for easy JSON authoring.
    private enum CodingKeys: String, CodingKey { case identity, stripSuffix }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .identity: try c.encode(true, forKey: .identity)
        case let .stripSuffix(s): try c.encode(s, forKey: .stripSuffix)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.contains(.stripSuffix) {
            self = try .stripSuffix(c.decode(String.self, forKey: .stripSuffix))
        } else {
            self = .identity
        }
    }
}
