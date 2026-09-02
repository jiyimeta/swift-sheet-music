import SheetMusicFoundation

/// Inserts one whole part — its instrument, its staves and a bar chain parallel to the score it joins — before
/// `partIndex`; `partIndex == parts.count` appends.
///
/// The new part's bars are measure rests carrying the score's **signature skeleton**: for every measure, whatever
/// key / time signature the reference staff declares there is copied onto the new bar, so a mid-score key or meter
/// change stays consistent across staves. Clefs are deliberately NOT copied — the new part declares its own opening
/// clef through `Staff.defaultClefType`, and inheriting the reference staff's would put a bass clef on a flute.
///
/// A bracket whose global span crosses the insertion point grows by the inserted staff count, matching MuseScore:
/// adding an instrument inside a bracketed group extends the group over it rather than leaving it hanging outside.
///
/// ## What carries a part index, and what this therefore re-stamps
///
/// Audited every `StaffAddress` in the model (`rg -n "StaffAddress" Sources/SheetMusicCore`) — exactly one model
/// field embeds one, and it is the only thing re-stamped here:
///
/// - `PositionedSystemElement.originalStaff` — the staff a tempo / rehearsal mark / staff text was attached to.
///   Every address whose own `partIndex` is at or past this command's insertion index moves one part down.
///
/// Everything else that looks like an address is not stored in the score:
///
/// - `VoiceElementID` / `RestID` / `NoteID` / `TupletID` / `ClefAnchor` / `ScoreItemID` are command and host
///   addressing types. They live in commands, selections and layout output, never in `Score`.
/// - `Spanner` stores `nextMeasuresOffset`, a relative MEASURE distance within one voice — a part insertion cannot
///   move it (unlike `InsertMeasure`, which must).
/// - `Tuplet` endpoints index into their own voice's element list; `Part` / `Staff` / `Measure` / `Voice` locate
///   themselves by nesting, so re-indexing is the array insertion itself.
///
/// ## One asymmetry worth knowing about
///
/// Reached through `ScoreEditSession.apply`, this command is bundled with `MeasureAccidentals`' renotation pass,
/// which diffs each post-edit staff against whatever staff previously held its address. A part insertion shifts
/// every address below it, so the staves BELOW the insertion point all read as changed and are re-notated — and
/// any glyph the pass would canonicalize there is written in the same undo step as the insertion. That is
/// deliberate and undo-exact (the composite's inverse restores both halves); it only means an add-part can also
/// tidy an accidental somewhere it did not touch. Applying `AddPart` directly through `ScoreEditor` skips the pass
/// entirely.
public struct AddPart: EditCommand {
    public let partIndex: Int
    /// The plan the new part is built from. `nil` on the restore path — when this command is the inverse of a
    /// `RemovePart`, `restoredPart` carries the exact part to put back instead.
    public let plan: BlankScoreTemplate.PartPlan?
    /// Set only when this command is the inverse of a `RemovePart`: the removed part, whole, rather than one
    /// rebuilt from a plan.
    let restoredPart: Part?
    /// Also inverse-only: every staff's `brackets` array as it stood before the removal, indexed
    /// `[partIndex][staffIndexInPart]` over the PRE-removal parts. Restoring by whole-value overwrite is exact
    /// even though the removal's re-anchor pass is not a simple span decrement — a bracket whose anchor staff was
    /// removed re-anchors onto another part entirely, which cannot be reversed by arithmetic.
    let restoredBrackets: [[[BracketItem]]]?
    /// Also inverse-only: every system element's `originalStaff` as it stood before the removal, indexed
    /// `[measureIndex][elementIndex]`. Captured for the same reason as `restoredBrackets`: an element anchored
    /// INTO the removed part is re-anchored onto the first staff, which loses the address it had.
    let restoredOriginalStaves: [[StaffAddress?]]?

    public init(plan: BlankScoreTemplate.PartPlan, at partIndex: Int) {
        self.partIndex = partIndex
        self.plan = plan
        restoredPart = nil
        restoredBrackets = nil
        restoredOriginalStaves = nil
    }

    init(
        restoring part: Part,
        at partIndex: Int,
        brackets: [[[BracketItem]]],
        originalStaves: [[StaffAddress?]],
    ) {
        self.partIndex = partIndex
        plan = nil
        restoredPart = part
        restoredBrackets = brackets
        restoredOriginalStaves = originalStaves
    }

    public var affectedLocation: VoiceElementID {
        VoiceElementID(
            staff: StaffAddress(partIndex: partIndex, staffIndexInPart: 0),
            measureIndex: 0, voiceIndex: 0, elementIndex: 0,
        )
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        // `!parts.isEmpty` for the same reason `InsertMeasure` requires it: a partless score has no reference
        // staff to take the signature skeleton or the measure count from, and nothing sensible to build against.
        guard partIndex >= 0, partIndex <= score.parts.count, !score.parts.isEmpty else {
            throw Self.refused(.targetNotFound(affectedLocation))
        }

        if let restoredPart {
            score.parts.insert(restoredPart, at: partIndex)
            restore(&score)
            return RemovePart(partIndex: partIndex)
        }

        guard let plan else { throw Self.refused(.emptyPayload) }
        let part = Self.builtPart(from: plan, joining: score)
        Self.growBracketsCrossing(partIndex, in: &score, byStaves: part.staves.count)
        Self.restampSystemElements(in: &score, fromPartIndex: partIndex)
        score.parts.insert(part, at: partIndex)
        return RemovePart(partIndex: partIndex)
    }

    /// The inverse-of-a-removal path: the part is already back in place, so the two captured pre-images are
    /// written over whatever the removal computed. Sized against the pre-removal score, which the insertion above
    /// has just restored, so the indices line up by construction.
    private func restore(_ score: inout Score) {
        if let restoredBrackets {
            for part in score.parts.indices where restoredBrackets.indices.contains(part) {
                for staff in score.parts[part].staves.indices
                    where restoredBrackets[part].indices.contains(staff)
                {
                    score.parts[part].staves[staff].brackets = restoredBrackets[part][staff]
                }
            }
        }
        guard let restoredOriginalStaves else { return }
        for measureIndex in score.systemMeasures.indices
            where restoredOriginalStaves.indices.contains(measureIndex)
        {
            for elementIndex in score.systemMeasures[measureIndex].elements.indices
                where restoredOriginalStaves[measureIndex].indices.contains(elementIndex)
            {
                score.systemMeasures[measureIndex].elements[elementIndex].originalStaff =
                    restoredOriginalStaves[measureIndex][elementIndex]
            }
        }
    }

    /// Builds the new part's bars from the score it is joining: one measure rest per existing measure, preceded by
    /// whatever key / time signature the reference staff declares in that same bar.
    ///
    /// `Part.init(blankPlan:id:measures:)` is the shared builder `Score.blank(_:)` uses, so the instrument wiring,
    /// the multi-staff brace and the percussion key-signature strip are all identical to a freshly created score.
    private static func builtPart(from plan: BlankScoreTemplate.PartPlan, joining score: Score) -> Part {
        let count = MeasureStructure.measureCount(of: score)
        let reference = signatureReference(in: score)
        let measures = (0 ..< count).map { index -> Measure in
            let voice = reference.measures.indices.contains(index)
                ? reference.measures[index].voices.first
                : nil
            let prefix = voice.map { MeasureStructure.leadingSignaturePrefix(of: $0).filter(isSignature) } ?? []
            return Measure(voices: [Voice(elements: prefix + [.rest(duration: .measure)])])
        }
        return Part(blankPlan: plan, id: nextPartID(in: score), measures: measures)
    }

    /// The staff the signature skeleton is read from: the first PITCHED staff, falling back to the very first one.
    /// A score whose part 0 is a drum kit carries no key signature there, and copying that skeleton onto a pitched
    /// part would silently drop the score's key.
    private static func signatureReference(in score: Score) -> Staff {
        for part in score.parts where !part.instrument.useDrumset {
            if let staff = part.staves.first(where: { $0.group != "percussion" }) { return staff }
        }
        // `apply` has already refused an empty score, so part 0 exists; a part with no staves at all is
        // degenerate enough that an empty stand-in is the right answer.
        return score.parts[0].staves.first ?? Staff()
    }

    /// Key and time only — a clef belongs to the staff that declares it, not to the score's signature skeleton.
    private static func isSignature(_ element: VoiceElement) -> Bool {
        switch element {
        case .keySignature, .timeSignature: true
        default: false
        }
    }

    /// The first free numeric part id. Taken from the MAXIMUM rather than the count so it stays unique against a
    /// loaded file's sparse or non-numeric ids ("1", "9", "flute" → "10"). Uniqueness is load-bearing: the session's
    /// part-index mapping diffs these ids to follow a part across an edit.
    private static func nextPartID(in score: Score) -> String {
        String((score.parts.compactMap { Int($0.id) }.max() ?? 0) + 1)
    }

    /// Grows every bracket whose global span crosses the insertion boundary by the number of staves being inserted.
    ///
    /// Only brackets anchored in the parts BEFORE `partIndex` can cross it — anything anchored at or after the
    /// boundary moves wholesale with its part and keeps its span. The predicate is the span analogue of
    /// `MeasureStructure.adjustSpannerOffsets(in:forInsertionAt:)`: a bracket anchored at global `g` covering
    /// `g … g+span-1` grows when `boundary <= g+span-1`, and an insertion landing exactly one past its last staff
    /// does not.
    private static func growBracketsCrossing(_ partIndex: Int, in score: inout Score, byStaves staffCount: Int) {
        guard partIndex > 0, staffCount > 0 else { return }
        let boundary = score.parts[0 ..< partIndex].reduce(0) { $0 + $1.staves.count }
        var globalIndex = 0
        for part in 0 ..< partIndex {
            for staff in score.parts[part].staves.indices {
                for bracket in score.parts[part].staves[staff].brackets.indices {
                    let span = score.parts[part].staves[staff].brackets[bracket].span
                    guard boundary <= globalIndex + span - 1 else { continue }
                    score.parts[part].staves[staff].brackets[bracket].span = span + staffCount
                }
                globalIndex += 1
            }
        }
    }

    /// Moves every system element anchored at or after the insertion point one part down, so a tempo or a `pizz.`
    /// keeps naming the staff it was written on.
    private static func restampSystemElements(in score: inout Score, fromPartIndex partIndex: Int) {
        for measureIndex in score.systemMeasures.indices {
            for elementIndex in score.systemMeasures[measureIndex].elements.indices {
                guard let address = score.systemMeasures[measureIndex].elements[elementIndex].originalStaff,
                      address.partIndex >= partIndex
                else { continue }
                score.systemMeasures[measureIndex].elements[elementIndex].originalStaff = StaffAddress(
                    partIndex: address.partIndex + 1,
                    staffIndexInPart: address.staffIndexInPart,
                )
            }
        }
    }
}
