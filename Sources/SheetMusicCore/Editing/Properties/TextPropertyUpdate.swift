import SheetMusicFoundation

/// An authored optional field has three edits: leave it alone, inherit again, or set an explicit value.
/// Unlike a single Optional, this does not confuse clearing an override with preserving it.
public enum TextPropertyUpdate<Value: Sendable & Equatable>: Sendable, Equatable {
    case unchanged
    case clear
    case set(Value)

    func applying(to previous: Value?) -> Value? {
        switch self {
        case .unchanged: previous
        case .clear: nil
        case let .set(value): value
        }
    }
}

extension SetTextFont {
    /// Five independent edits. Defaults preserve every field; clearing must be explicit.
    /// The wire flattens these fields with individual three-state tags, never serializes a score subtree.
    public struct Patch: Sendable, Equatable {
        public var face: TextPropertyUpdate<String>
        public var size: TextPropertyUpdate<Double>
        public var style: TextPropertyUpdate<FontStyleSet>
        public var frameType: TextPropertyUpdate<TextFrameType>
        public var framePadding: TextPropertyUpdate<Double>

        public init(
            face: TextPropertyUpdate<String> = .unchanged,
            size: TextPropertyUpdate<Double> = .unchanged,
            style: TextPropertyUpdate<FontStyleSet> = .unchanged,
            frameType: TextPropertyUpdate<TextFrameType> = .unchanged,
            framePadding: TextPropertyUpdate<Double> = .unchanged,
        ) {
            self.face = face
            self.size = size
            self.style = style
            self.frameType = frameType
            self.framePadding = framePadding
        }

        public func applying(to previous: TextProperties) -> TextProperties {
            TextProperties(
                face: face.applying(to: previous.face), size: size.applying(to: previous.size),
                style: style.applying(to: previous.style), frameType: frameType.applying(to: previous.frameType),
                framePadding: framePadding.applying(to: previous.framePadding),
            )
        }

        /// Match the fingerprint's UTF-8 bytes and Double bits, including signed zero and NaN payloads.
        public func changes(_ previous: TextProperties) -> Bool {
            let next = applying(to: previous)
            return next.face.map { Array($0.utf8) } != previous.face.map { Array($0.utf8) }
                || next.size?.bitPattern != previous.size?.bitPattern
                || next.style != previous.style || next.frameType != previous.frameType
                || next.framePadding?.bitPattern != previous.framePadding?.bitPattern
        }

        /// Restore only fields the forward patch wrote; unrelated fields are not part of this undo.
        func restoring(_ previous: TextProperties) -> Self {
            Self(
                face: face.restoring(previous.face), size: size.restoring(previous.size),
                style: style.restoring(previous.style), frameType: frameType.restoring(previous.frameType),
                framePadding: framePadding.restoring(previous.framePadding),
            )
        }
    }
}

extension TextPropertyUpdate {
    fileprivate func restoring(_ previous: Value?) -> Self {
        if case .unchanged = self { return .unchanged }
        return previous.map(Self.set) ?? .clear
    }
}
