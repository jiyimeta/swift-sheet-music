import Foundation
import SheetMusicCore

/// Knobs for `MSCXEncoder.encode(_:options:)`.
///
/// `targetVersion` selects which MuseScore wire-form variant the
/// encoder produces. Defaults to `.v4` so existing call sites that
/// use the zero-arg `encode(_:)` overload retain MS4 output.
public struct MSCXEncoderOptions: Sendable {
    public var targetVersion: MSCXVersion

    public init(targetVersion: MSCXVersion = .v4) {
        self.targetVersion = targetVersion
    }
}
