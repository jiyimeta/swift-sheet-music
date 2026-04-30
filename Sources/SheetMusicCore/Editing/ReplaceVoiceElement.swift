import Foundation

/// Replaces the `VoiceElement` at `location` with `element`.
///
/// The most primitive editing command: every other command in this
/// library could be expressed in terms of one or more of these.
public struct ReplaceVoiceElement: EditCommand {
    public let location: VoiceElementID
    public let element: VoiceElement

    public init(at location: VoiceElementID, with element: VoiceElement) {
        self.location = location
        self.element = element
    }

    public var affectedLocation: VoiceElementID { location }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard let old = score[location] else {
            throw SheetMusicError.invalidEdit(
                reason: "ReplaceVoiceElement: no element at \(location)")
        }
        score[location] = element
        return ReplaceVoiceElement(at: location, with: old)
    }
}
