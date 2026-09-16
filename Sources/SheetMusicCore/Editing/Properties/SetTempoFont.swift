import SheetMusicFoundation

/// Patches the authored font overrides on the tempo marking at the beat of the chord or rest at `anchor`,
/// with `SetTextFont`'s three-state `Patch`.
///
/// Its own command rather than a fifth `ScoreTextID` case because a tempo is not addressed as text anywhere
/// else: a click selects it as `ScoreElementID.tempo(anchor:)`, and `SetTempo` writes it by the same anchor.
/// Giving it a second identity in the text vocabulary would let one mark be selected under two names. The
/// lookup is `SetTempo`'s own (`SetTempo.slot(at:in:)`), so "the tempo here" means the same mark to the
/// writer of its marking, of its color (`SetElementColor.Target.tempo`) and of its font.
///
/// Face, size and bold/italic are drawn (face subject to font fallback, and not carried on Android's draw
/// program); underline, strike, `frameType` and `framePadding` are written and preserved through MSCX but not
/// drawn — the same row `SetTextFont` documents for the other texts. The inverse restores only the fields the
/// patch addresses. A beat with no tempo is refused as `.targetNotFound`.
public struct SetTempoFont: EditCommand {
    public let anchor: VoiceElementID
    public let patch: SetTextFont.Patch

    public init(anchor: VoiceElementID, patch: SetTextFont.Patch) {
        self.anchor = anchor
        self.patch = patch
    }

    public var affectedLocation: VoiceElementID {
        anchor
    }

    @discardableResult
    public func apply(to score: inout Score, ids: inout EIDAllocator) throws -> any EditCommand {
        guard let slot = SetTempo.slot(at: anchor, in: score),
              case var .tempo(tempo) = score.systemMeasures[slot.measureIndex].elements[slot.elementIndex].element
        else { throw Self.refused(.targetNotFound(anchor)) }
        let previous = tempo.properties
        tempo.properties = patch.applying(to: previous)
        score.systemMeasures.updateValue(at: slot.measureIndex) {
            $0.elements.updateValue(at: slot.elementIndex) { $0.element = .tempo(tempo) }
        }
        return SetTempoFont(anchor: anchor, patch: patch.restoring(previous))
    }

    /// The overrides on the tempo at the anchor's beat, or `nil` when that beat carries no tempo. Nil is an
    /// absent carrier, not a carrier whose overrides are all nil — the planner refuses the first and plans the
    /// second to nothing when the patch changes no field.
    public static func current(at anchor: VoiceElementID, in score: Score) -> TextProperties? {
        SetTempo.tempo(at: anchor, in: score)?.properties
    }
}
