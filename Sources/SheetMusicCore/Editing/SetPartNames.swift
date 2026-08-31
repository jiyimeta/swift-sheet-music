import SheetMusicFoundation

/// Renames the part at `partIndex`: the long name engraved at the left of the first system, and the abbreviation
/// engraved there on every system after it.
///
/// Both names in one command, because they are one question asked twice. A host editing only one of them passes
/// the other's current value; a host editing both — which is what a part-properties sheet does — gets one undo
/// step rather than two, so taking a rename back does not leave the score half-renamed.
///
/// ## `nil` means "no name", not "leave it alone"
///
/// Both fields are optional in the model and both are written verbatim, so `nil` clears. That is deliberate and it
/// is the only honest reading: `Instrument.shortName` is what the layout engine labels systems 2+ with, and a part
/// that should carry no label there has to be able to say so. A "leave unchanged" sentinel would need a third
/// state the model does not have, and would make the inverse ambiguous.
///
/// ## What this does NOT touch
///
/// - **`Part.trackName`**, which is the instrument's own name as the file recorded it ("Piano"), not the part's.
///   A part renamed to "なおき" is still a piano, and that is exactly what a host reads `trackName` back for when
///   the instrument id is one it does not know.
/// - **`Instrument.id`**, so a renamed part keeps playing what it plays: the sound, the transposition, the drum
///   kit and the catalog identity are all keyed off it.
///
/// Renaming changes no structure — no staff appears or disappears, no bracket moves, no address shifts — so unlike
/// the other part-level commands there is nothing to re-derive and nothing to re-stamp.
public struct SetPartNames: EditCommand {
    public let partIndex: Int
    public let longName: String?
    public let shortName: String?

    public init(partIndex: Int, longName: String?, shortName: String?) {
        self.partIndex = partIndex
        self.longName = longName
        self.shortName = shortName
    }

    /// The renamed part's first staff, first bar — a host scrolling to the affected slot wants to see the label
    /// that just changed, which is drawn there.
    public var affectedLocation: VoiceElementID {
        VoiceElementID(
            staff: StaffAddress(partIndex: partIndex, staffIndexInPart: 0),
            measureIndex: 0, voiceIndex: 0, elementIndex: 0,
        )
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard score.parts.indices.contains(partIndex) else {
            throw Self.refused(.targetNotFound(affectedLocation))
        }

        let previousLongName = score.parts[partIndex].instrument.longName
        let previousShortName = score.parts[partIndex].instrument.shortName

        score.parts[partIndex].instrument.longName = longName
        score.parts[partIndex].instrument.shortName = shortName

        return SetPartNames(
            partIndex: partIndex,
            longName: previousLongName,
            shortName: previousShortName,
        )
    }
}
