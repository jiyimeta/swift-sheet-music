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
/// ## The part name follows the long name
///
/// A new long name is written to `Part.trackName` as well. That field is MuseScore's PART NAME — `<Part><trackName>`,
/// read into `Part::partName()` by both MuseScore 3.6 (`libmscore/part.cpp`) and 4.x (`read410/tread.cpp`) — and it
/// is what their Mixer, their instrument list and their Parts dialog call the part, while the long name is only the
/// label engraved at the staff. Renaming the label alone left a file that MuseScore showed under the new name on the
/// page and the old one everywhere else. MuseScore's own development line after 4.7 settles the pair the same way:
/// there `Part::partName()` is derived from the long name and no longer read from the file.
///
/// Only a CHANGED long name moves it. A file can name a part apart from its label ("Flute 1" beside "Flute"), and an
/// edit to the abbreviation alone is no reason to overwrite that. The inverse restores the part name it found, so
/// one undo takes the whole rename back.
///
/// ## What this does NOT touch
///
/// - **`Instrument.trackName`**, the instrument's own name ("Piano"), which is what a host reads back to say what a
///   part renamed "なおき" plays when the instrument id is one it does not know. MuseScore fills an empty part name
///   from it, too.
/// - **`Instrument.id`**, so a renamed part keeps playing what it plays: the sound, the transposition, the drum
///   kit and the catalog identity are all keyed off it.
///
/// Renaming changes no structure — no staff appears or disappears, no bracket moves, no address shifts — so unlike
/// the other part-level commands there is nothing to re-derive and nothing to re-stamp.
public struct SetPartNames: EditCommand {
    public let partIndex: Int
    public let longName: String?
    public let shortName: String?

    /// What the command writes to `Part.trackName`: the new long name when it changes, or — for an inverse — exactly
    /// the part name the forward edit found.
    private let partName: PartNameWrite

    private enum PartNameWrite {
        case followsLongName
        case restores(String?)
    }

    public init(partIndex: Int, longName: String?, shortName: String?) {
        self.init(partIndex: partIndex, longName: longName, shortName: shortName, partName: .followsLongName)
    }

    private init(partIndex: Int, longName: String?, shortName: String?, partName: PartNameWrite) {
        self.partIndex = partIndex
        self.longName = longName
        self.shortName = shortName
        self.partName = partName
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
    public func apply(to score: inout Score, ids: inout EIDAllocator) throws -> any EditCommand {
        guard score.parts.indices.contains(partIndex) else {
            throw Self.refused(.targetNotFound(affectedLocation))
        }

        let previousLongName = score.parts[partIndex].instrument.longName
        let previousShortName = score.parts[partIndex].instrument.shortName
        let previousPartName = score.parts[partIndex].trackName
        let newPartName = switch partName {
        case .followsLongName: longName == previousLongName ? previousPartName : longName
        case let .restores(name): name
        }

        score.parts.updateValue(at: partIndex) { partValue in
            partValue.instrument.longName = longName
            partValue.instrument.shortName = shortName
            partValue.trackName = newPartName
        }

        return SetPartNames(
            partIndex: partIndex,
            longName: previousLongName,
            shortName: previousShortName,
            partName: .restores(previousPartName),
        )
    }
}
