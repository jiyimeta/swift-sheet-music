import SheetMusicCore
import SheetMusicFoundation
import Wirelet

// Payload structs for intents 58…61 (edit-command parity, group 5). Tag layouts are documented in
// `EditIntentCodec.swift`'s file-level comment alongside the older payloads; the rules there apply unchanged —
// every field mandatory, a bool as `u8` (0 / 1 written, any non-zero read as true). The four structs are pairwise
// byte-identical and still separate: the discriminator names the intent, the struct names its target kind.

@WireFormat
public struct SetElementVisibleIntentWire {
    public var location: VoiceElementIDWire
    public var visible: UInt8

    public init(location: VoiceElementID, visible: Bool) {
        self.location = VoiceElementIDWire(from: location)
        self.visible = visible ? 1 : 0
    }

    public func decoded() -> (location: VoiceElementID, visible: Bool) {
        (location: location.decoded(), visible: visible != 0)
    }
}

@WireFormat
public struct SetNoteVisibleIntentWire {
    public var location: NoteIDWire
    public var visible: UInt8

    public init(location: NoteID, visible: Bool) {
        self.location = NoteIDWire(from: location)
        self.visible = visible ? 1 : 0
    }

    public func decoded() -> (location: NoteID, visible: Bool) {
        (location: location.decoded(), visible: visible != 0)
    }
}

@WireFormat
public struct SetStemVisibleIntentWire {
    public var location: VoiceElementIDWire
    public var visible: UInt8

    public init(location: VoiceElementID, visible: Bool) {
        self.location = VoiceElementIDWire(from: location)
        self.visible = visible ? 1 : 0
    }

    public func decoded() -> (location: VoiceElementID, visible: Bool) {
        (location: location.decoded(), visible: visible != 0)
    }
}

/// `location` is the chord the host addressed, not the beam leader: both images re-target to the leader while
/// planning (`ScoreEditSession.visibilityCommand`), so the bytes stay what the host said and the two sides agree
/// by running the same rule rather than by one telling the other the answer.
@WireFormat
public struct SetBeamVisibleIntentWire {
    public var location: VoiceElementIDWire
    public var visible: UInt8

    public init(location: VoiceElementID, visible: Bool) {
        self.location = VoiceElementIDWire(from: location)
        self.visible = visible ? 1 : 0
    }

    public func decoded() -> (location: VoiceElementID, visible: Bool) {
        (location: location.decoded(), visible: visible != 0)
    }
}
