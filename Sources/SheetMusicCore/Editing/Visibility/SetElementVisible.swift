import SheetMusicFoundation

/// Shows or hides one element of a voice — MuseScore's `V` on a clef, a barline, a dynamic, a rest — by writing
/// its `elementProperties.visible`. Playback is unaffected (`ElementProperties.visible` doc).
///
/// Every `VoiceElement` case that carries `ElementProperties` is accepted: chord (a rest is a chord), clef,
/// barline, key and time signature, dynamic, fermata, breath, spanner, harmony, sticking, expression, capo, and
/// string tunings. A measure repeat, location shift, and preserved source node carry none and are refused as
/// `.wrongElementKind(expected: .engravable)`.
///
/// On a chord this is the model's whole-chord switch (`Chord.visible`, what the layout reads as `chordFullyHidden`).
/// MuseScore has no such flag — `Chord::getProperty(Pid::VISIBLE)` is always true and `V` on a chord fans out to
/// its notes, stem, hook and articulations — so this command deliberately does NOT rewrite the per-note flags: undo
/// is one field, and a note hidden on its own (`SetNoteVisible`) stays hidden after the chord is shown again, as
/// MuseScore's per-element flags would.
///
/// > Note: This command is sugar over `ReplaceVoiceElement`. It exists to give the operation a domain-meaningful
/// > name and to own the case list above; callers can equally construct the primitive directly. See
/// > `docs/edit-commands.md`.
public struct SetElementVisible: EditCommand {
    public let location: VoiceElementID
    public let visible: Bool

    public init(at location: VoiceElementID, visible: Bool) {
        self.location = location
        self.visible = visible
    }

    public var affectedLocation: VoiceElementID {
        location
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard let element = score[location] else { throw Self.refused(.targetNotFound(location)) }
        guard let old = Self.visibility(of: element), let updated = Self.setting(element, visible: visible) else {
            throw Self.refused(.wrongElementKind(at: location, expected: .engravable))
        }
        score[location] = updated
        return SetElementVisible(at: location, visible: old)
    }

    /// The flag on the element at `location`; `nil` for a missing slot or an element that carries none.
    static func current(at location: VoiceElementID, in score: Score) -> Bool? {
        score[location].flatMap(visibility(of:))
    }

    static func visibility(of element: VoiceElement) -> Bool? {
        switch element {
        case let .chord(chord): chord.visible
        case let .clef(clef): clef.visible
        case let .barLine(barLine): barLine.visible
        case let .keySignature(key): key.visible
        case let .timeSignature(time): time.visible
        case let .dynamic(dynamic): dynamic.visible
        case let .fermata(fermata): fermata.visible
        case let .breath(breath): breath.visible
        case let .spanner(spanner): spanner.visible
        case let .harmony(harmony): harmony.visible
        case let .sticking(sticking): sticking.visible
        case let .expression(expression): expression.visible
        case let .capo(capo): capo.visible
        case let .stringTunings(tunings): tunings.visible
        case .measureRepeat, .locationShift, .preserved: nil
        }
    }

    private static func setting(_ element: VoiceElement, visible: Bool) -> VoiceElement? {
        switch element {
        case var .chord(chord):
            chord.visible = visible
            return .chord(chord)
        case var .clef(clef):
            clef.visible = visible
            return .clef(clef)
        case var .barLine(barLine):
            barLine.visible = visible
            return .barLine(barLine)
        case var .keySignature(key):
            key.visible = visible
            return .keySignature(key)
        case var .timeSignature(time):
            time.visible = visible
            return .timeSignature(time)
        case var .dynamic(dynamic):
            dynamic.visible = visible
            return .dynamic(dynamic)
        case var .fermata(fermata):
            fermata.visible = visible
            return .fermata(fermata)
        case var .breath(breath):
            breath.visible = visible
            return .breath(breath)
        case var .spanner(spanner):
            spanner.visible = visible
            return .spanner(spanner)
        case var .harmony(harmony):
            harmony.visible = visible
            return .harmony(harmony)
        case var .sticking(sticking):
            sticking.visible = visible
            return .sticking(sticking)
        case var .expression(expression):
            expression.visible = visible
            return .expression(expression)
        case var .capo(capo):
            capo.visible = visible
            return .capo(capo)
        case var .stringTunings(tunings):
            tunings.visible = visible
            return .stringTunings(tunings)
        case .measureRepeat, .locationShift, .preserved:
            return nil
        }
    }
}
