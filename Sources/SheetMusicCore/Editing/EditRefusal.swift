import SheetMusicFoundation

/// Why the editing engine refused an edit: the structured payload of
/// `SheetMusicError.invalidEdit`, and the value behind
/// `ScoreEditSession.lastRefusal`. Apps switch over `reason` to produce
/// their own localized copy; bridges surface `code` + `developerDescription`.
public struct EditRefusal: Sendable, Hashable {
    /// The command or entry point that refused, as a type/function name:
    /// `"DeleteVoiceElement"`, `"undo"`, `"writeNote"`. An identifier for
    /// logs and triage, never prose.
    public let operation: String
    public let reason: Reason

    public init(operation: String, reason: Reason) {
        self.operation = operation
        self.reason = reason
    }

    /// What kind of element a command needed at its target.
    public enum ExpectedKind: String, Sendable {
        case chord
        case rest
        case chordOrRest
        case timed
        case tuplet
    }

    public enum Reason: Sendable, Hashable {
        case targetNotFound(VoiceElementID)
        case noteNotFound(NoteID)
        case staffNotFound(StaffAddress)
        case wrongElementKind(at: VoiceElementID, expected: ExpectedKind)
        case insufficientRoom(neededTicks: Int, availableTicks: Int)
        case blockedByUntimedElement(at: VoiceElementID)
        case insideTuplet(at: VoiceElementID)
        case indivisibleTuplet(targetTicks: Int, actualNotes: Int)
        case invalidTupletRatio(actualNotes: Int, normalNotes: Int)
        case tupletOverlap(rangeStart: Int, rangeEnd: Int, tupletStart: Int, tupletEnd: Int)
        case duplicatePitch(Int)
        case emptyPayload
        case nothingToUndo
        case nothingToRedo
        case compositeTooDeep(limit: Int)
        case nothingToApply
        /// A score must keep at least one measure; `DeleteMeasure` refuses when it would remove the last one.
        case cannotDeleteOnlyMeasure
        /// A score must keep at least one part; `RemovePart` refuses when it would remove the last one. Distinct
        /// from `.targetNotFound` on purpose: a host showing "no such part" when the user tried to delete their
        /// only instrument is telling them something untrue.
        case cannotRemoveLastPart
        /// A score's OPENING key signature is the score's key, not a change to it; `RemoveKeySignature` refuses at
        /// measure 0. Distinct from `.targetNotFound` for the same reason `.cannotRemoveLastPart` is: there IS a
        /// signature there, and a host saying otherwise would be telling the user something untrue. The way to
        /// change what bar 1 declares is `.setKeySignature`, which has no "remove" to refuse.
        case cannotRemoveInitialSignature
        /// Re-barring a region at a new meter would put a new barline inside a tuplet. A tuplet is an
        /// indivisible rhythmic unit — its members' lengths are the tuplet's to decide — so the region is
        /// refused rather than re-spelled into something no engraver would write. `measureIndex` names the
        /// PRE-EDIT bar the tuplet lives in, so a host can point at it.
        case rebarWouldSplitTuplet(measureIndex: Int)
        /// Re-barring a region at a new meter would move a barline marker — a repeat sign, a `Marker` /
        /// `Jump`, or a special barline — off the barline it marks. Such a marker only means anything ON a
        /// barline, so the region is refused rather than have it silently slide. `measureIndex` names the
        /// PRE-EDIT bar carrying the marker.
        case rebarWouldDisplaceBarlineMarker(measureIndex: Int)
        /// A non-`invalidEdit` error escaped a command: a bug kept visible
        /// rather than crashed on. Constructed only by
        /// `ScoreEditSession.refusal(for:operation:)`; the free text is a
        /// stringified foreign error, not authored prose.
        case unexpected(description: String)
    }

    /// Stable dotted identifier under the `edit.` namespace.
    public var code: String {
        switch reason {
        case .targetNotFound:
            "edit.targetNotFound"
        case .noteNotFound:
            "edit.noteNotFound"
        case .staffNotFound:
            "edit.staffNotFound"
        case .wrongElementKind:
            "edit.wrongElementKind"
        case .insufficientRoom:
            "edit.insufficientRoom"
        case .blockedByUntimedElement:
            "edit.blockedByUntimedElement"
        case .insideTuplet:
            "edit.insideTuplet"
        case .indivisibleTuplet:
            "edit.indivisibleTuplet"
        case .invalidTupletRatio:
            "edit.invalidTupletRatio"
        case .tupletOverlap:
            "edit.tupletOverlap"
        case .duplicatePitch:
            "edit.duplicatePitch"
        case .emptyPayload:
            "edit.emptyPayload"
        case .nothingToUndo:
            "edit.nothingToUndo"
        case .nothingToRedo:
            "edit.nothingToRedo"
        case .compositeTooDeep:
            "edit.compositeTooDeep"
        case .nothingToApply:
            "edit.nothingToApply"
        case .cannotDeleteOnlyMeasure:
            "edit.cannotDeleteOnlyMeasure"
        case .cannotRemoveLastPart:
            "edit.cannotRemoveLastPart"
        case .cannotRemoveInitialSignature:
            "edit.cannotRemoveInitialSignature"
        case .rebarWouldSplitTuplet:
            "edit.rebarWouldSplitTuplet"
        case .rebarWouldDisplaceBarlineMarker:
            "edit.rebarWouldDisplaceBarlineMarker"
        case .unexpected:
            "edit.unexpected"
        }
    }

    /// `"<operation>: <derived English>"`.
    public var developerDescription: String {
        "\(operation): \(reasonDescription)"
    }

    private var reasonDescription: String {
        switch reason {
        case let .targetNotFound(location):
            "no element at \(location)"
        case let .noteNotFound(noteID):
            "no note at \(noteID)"
        case let .staffNotFound(address):
            "no staff at \(address)"
        case let .wrongElementKind(location, expected):
            "element at \(location) is not \(expected.description)"
        case let .insufficientRoom(neededTicks, availableTicks):
            "not enough room in the measure (need \(neededTicks), have \(availableTicks))"
        case let .blockedByUntimedElement(location):
            "element at \(location) has no duration"
        case let .insideTuplet(location):
            "element at \(location) is inside a tuplet"
        case let .indivisibleTuplet(targetTicks, actualNotes):
            "cannot divide \(targetTicks) ticks into \(actualNotes) tuplet notes"
        case let .invalidTupletRatio(actualNotes, normalNotes):
            "invalid tuplet ratio \(actualNotes):\(normalNotes)"
        case let .tupletOverlap(rangeStart, rangeEnd, tupletStart, tupletEnd):
            "tuplet range \(tupletStart)..<\(tupletEnd) overlaps \(rangeStart)..<\(rangeEnd)"
        case let .duplicatePitch(pitch):
            "pitch \(pitch) already exists in the chord"
        case .emptyPayload:
            "empty payload"
        case .nothingToUndo:
            "nothing to undo"
        case .nothingToRedo:
            "nothing to redo"
        case let .compositeTooDeep(limit):
            "composite edit exceeded depth limit \(limit)"
        case .nothingToApply:
            "intent resolved to nothing to apply"
        case .cannotDeleteOnlyMeasure:
            "a score must keep at least one measure"
        case .cannotRemoveLastPart:
            "a score must keep at least one part"
        case .cannotRemoveInitialSignature:
            "a score's opening signature cannot be removed"
        case let .rebarWouldSplitTuplet(measureIndex):
            "re-barring would split the tuplet in measure \(measureIndex)"
        case let .rebarWouldDisplaceBarlineMarker(measureIndex):
            "re-barring would displace the barline marker on measure \(measureIndex)"
        case let .unexpected(description):
            "unexpected error: \(description)"
        }
    }
}

extension EditRefusal.ExpectedKind {
    fileprivate var description: String {
        switch self {
        case .chord:
            "a chord"
        case .rest:
            "a rest"
        case .chordOrRest:
            "a chord or rest"
        case .timed:
            "a timed element"
        case .tuplet:
            "a tuplet"
        }
    }
}
