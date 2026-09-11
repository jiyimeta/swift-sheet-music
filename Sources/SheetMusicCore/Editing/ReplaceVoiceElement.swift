import SheetMusicFoundation

/// Replaces the `VoiceElement` at `location` with `element`.
///
/// The most primitive editing command: every other command in this
/// library could be expressed in terms of one or more of these.
public struct ReplaceVoiceElement: EditCommand {
    public let location: VoiceElementID
    public let element: VoiceElement
    public let identity: ElementIdentity

    public init(at location: VoiceElementID, with element: VoiceElement) {
        self.init(at: location, with: element, identity: .same)
    }

    public init(at location: VoiceElementID, with element: VoiceElement, identity: ElementIdentity) {
        self.location = location
        self.element = element
        self.identity = identity
    }

    public var affectedLocation: VoiceElementID {
        location
    }

    @discardableResult
    public func apply(to score: inout Score, ids: inout EIDAllocator) throws -> any EditCommand {
        guard let old = score[location] else {
            throw Self.refused(.targetNotFound(location))
        }
        let ref = VoiceRef(location)
        guard var voice = score[voice: ref] else { throw Self.refused(.targetNotFound(location)) }
        let previous = voice.elements.eid(at: location.elementIndex)
        let inverseIdentity: ElementIdentity
        var materialized = element
        switch identity {
        case .same:
            materialized.assignMissingNestedIDs(using: &ids)
            voice.elements.updateValue(at: location.elementIndex) { $0 = materialized }
            inverseIdentity = .same
        case .fresh:
            let eid = ids.next()
            materialized = materialized.clearingNestedIDsForCopy()
            materialized.assignMissingNestedIDs(using: &ids)
            voice.replaceElement(at: location.elementIndex, with: materialized, id: eid)
            inverseIdentity = .restore(previous)
        case let .restore(restored):
            materialized.assignMissingNestedIDs(using: &ids)
            voice.replaceElement(at: location.elementIndex, with: materialized, id: restored)
            inverseIdentity = .restore(previous)
        }
        score[voice: ref] = voice
        return ReplaceVoiceElement(at: location, with: old, identity: inverseIdentity)
    }
}
