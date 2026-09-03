import SheetMusicFoundation

/// The one placement engine behind every spanner command (spec 2026-09-02 §3.2). Ten `set…` commands and one
/// `RemoveSpanner` are names over this; nothing else in the package decides where a spanner goes.
///
/// Three storage forms, because MuseScore has three:
///
/// - **`.slur`** rides in the start `Chord.spanners` array (`TWrite::writeProperties(const ChordRest*…)` writes
///   spanner starts inside `<Chord>`), and its `tick2` is the END CHORD'S ONSET — `edit.cpp`'s `addSlur` makes
///   the last chord the `endElement`, and a slur is drawn note-head to note-head, not through the last note.
/// - **Every line spanner** is a `.spanner` `VoiceElement` immediately before the start chord — the order the
///   decoder keeps and MuseScore writes (`testSingleNoteDynamics.mscx:96-110`: `<Dynamic>`, `<Spanner
///   type="HairPin">`, `<Chord>`) — and its `tick2` is the END TICK of the range's last element, so a hairpin
///   over one whole note covers the bar.
/// - **`.volta`** is measure-granular: index 0 of voice 0 of the range's first measure on `Score.canonicalStaff`
///   (`testVoltaDynamic.mscx:217-220` puts it ahead of the bar's own signatures), ending at the end of the
///   range's last measure. It ignores the range's staff and voice entirely, the way every other measure-level
///   flag does (§3.1, "Measure-level flags — one canonical staff").
///
/// A `VoiceElementRange` names a rectangle; a spanner lives in one track. The bound with the EARLIER onset is the
/// anchor, and only the elements of `Score.voiceElements(in:)` sharing that bound's `(staff, voice)` are the
/// span — MuseScore's `cmdAddSpanner` puts the spanner in the selection's start track the same way. So a range
/// given in either order, or one that reaches across staves, narrows rather than refuses.
///
/// Every mutation is returned as a command, never applied here: an insert is a voice-level `ReplaceVoiceElements`
/// through `AdjacentElementSlot` (tuplets remapped by `MeasureStructure.remapTuplets`, indices restored exactly by
/// its inverse), and the chord-anchored form is a `ReplaceVoiceElement`.
enum SpannerPlacement {
    enum Storage: Equatable {
        case chordAnchored
        case voiceElement
        case measureVolta
    }

    static func storage(of kind: Spanner.Kind) -> Storage {
        switch kind {
        case .slur: .chordAnchored
        case .volta: .measureVolta
        default: .voiceElement
        }
    }

    /// The (anchor, last) pair `range` collapses to, in one (staff, voice); `nil` when it resolves to nothing.
    static func run(
        of range: VoiceElementRange, in score: Score,
    ) -> (anchor: VoiceElementID, last: VoiceElementID)? {
        guard let startOnset = score.onset(of: range.start), let endOnset = score.onset(of: range.end) else {
            return nil
        }
        let anchorBound = startOnset <= endOnset ? range.start : range.end
        let members = score.voiceElements(in: range).filter {
            $0.staff == anchorBound.staff && $0.voiceIndex == anchorBound.voiceIndex
        }
        guard let first = members.first, let last = members.last else { return nil }
        return (anchor: first, last: last)
    }

    /// The command that writes `template` over `range`, its offsets filled in. Throws every refusal.
    static func add(_ template: Spanner, over range: VoiceElementRange, in score: Score) throws -> any EditCommand {
        switch storage(of: template.kind) {
        case .measureVolta:
            return try addVolta(template, over: range, in: score)
        case .chordAnchored, .voiceElement:
            guard let (anchor, last) = run(of: range, in: score) else {
                throw refused(.targetNotFound(range.start), operation: "setSpanner")
            }
            let form = storage(of: template.kind)
            if form == .chordAnchored, anchor == last {
                throw refused(.noNextChord(at: anchor), operation: "setSpanner")
            }
            guard let endPosition = form == .chordAnchored ? score.onset(of: last) : score.end(of: last),
                  let offsets = Spanner.offsets(from: anchor, to: endPosition, in: score)
            else {
                throw refused(.targetNotFound(last), operation: "setSpanner")
            }
            try refuseDuplicate(template.kind, at: anchor, in: score)
            var spanner = template
            spanner.nextMeasuresOffset = offsets.measures
            spanner.nextFractionsOffset = offsets.fractions
            return form == .chordAnchored
                ? try attach(spanner, to: anchor, in: score)
                : try insert(spanner, before: anchor, in: score)
        }
    }

    /// The command that takes `kind` off the element at `location`. Throws every refusal.
    static func remove(
        _ kind: Spanner.Kind, at location: VoiceElementID, in score: Score,
    ) throws -> any EditCommand {
        guard let element = score[location] else {
            throw refused(.targetNotFound(location), operation: "removeSpanner")
        }
        let form = storage(of: kind)
        switch (form, element) {
        case let (.chordAnchored, .chord(chord)):
            guard chord.spanners.contains(where: { $0.kind == kind }) else {
                throw refused(.noSpannerAtLocation(location), operation: "removeSpanner")
            }
            var stripped = chord
            stripped.spanners.removeAll { $0.kind == kind }
            return AdjacentElementSlot.replacing(.chord(stripped), at: location.elementIndex, in: VoiceRef(location))
        case let (_, .spanner(spanner)) where form != .chordAnchored:
            guard spanner.kind == kind else {
                throw refused(.noSpannerAtLocation(location), operation: "removeSpanner")
            }
            guard let command = AdjacentElementSlot.removing(
                at: location.elementIndex, in: VoiceRef(location), of: score,
            ) else {
                throw refused(.targetNotFound(location), operation: "removeSpanner")
            }
            return command
        default:
            throw refused(
                .wrongElementKind(at: location, expected: form == .chordAnchored ? .chord : .spanner),
                operation: "removeSpanner",
            )
        }
    }

    private static func refused(_ reason: EditRefusal.Reason, operation: String) -> SheetMusicError {
        .invalidEdit(EditRefusal(operation: operation, reason: reason))
    }
}

extension SpannerPlacement {
    /// The volta's own resolution: first and last MEASURE of the range, both re-homed to the canonical staff.
    private static func addVolta(
        _ template: Spanner, over range: VoiceElementRange, in score: Score,
    ) throws -> any EditCommand {
        let bounds = [range.start.measureIndex, range.end.measureIndex]
        let first = bounds.min() ?? 0
        let last = bounds.max() ?? 0
        let anchor = VoiceElementID(
            staff: Score.canonicalStaff, measureIndex: first, voiceIndex: 0, elementIndex: 0,
        )
        guard let staff = score[Score.canonicalStaff], staff.measures.indices.contains(last),
              score[voice: VoiceRef(anchor)] != nil
        else {
            throw refused(.targetNotFound(anchor), operation: "setVolta")
        }
        let durations = staff.measures.effectiveMeasureDurations()
        let end = ScoreTickPosition(measure: last, tick: durations[last].ticks(division: score.division))
        guard let offsets = Spanner.offsets(from: anchor, to: end, in: score) else {
            throw refused(.targetNotFound(anchor), operation: "setVolta")
        }
        try refuseDuplicate(.volta, at: anchor, in: score)
        var spanner = template
        spanner.nextMeasuresOffset = offsets.measures
        spanner.nextFractionsOffset = offsets.fractions
        return try insert(spanner, at: 0, in: VoiceRef(anchor), of: score, reporting: anchor)
    }

    /// `Chord.spanners` grows by one; no element index moves, so this is a plain in-place replace.
    private static func attach(
        _ spanner: Spanner, to anchor: VoiceElementID, in score: Score,
    ) throws -> any EditCommand {
        guard case let .chord(chord)? = score[anchor] else {
            throw refused(.wrongElementKind(at: anchor, expected: .chord), operation: "setSpanner")
        }
        var updated = chord
        updated.spanners.append(spanner)
        return AdjacentElementSlot.replacing(.chord(updated), at: anchor.elementIndex, in: VoiceRef(anchor))
    }

    private static func insert(
        _ spanner: Spanner, before anchor: VoiceElementID, in score: Score,
    ) throws -> any EditCommand {
        try insert(
            spanner, at: AdjacentElementSlot.insertionIndex(.before, of: anchor.elementIndex),
            in: VoiceRef(anchor), of: score, reporting: anchor,
        )
    }

    private static func insert(
        _ spanner: Spanner, at index: Int, in voice: VoiceRef, of score: Score, reporting anchor: VoiceElementID,
    ) throws -> any EditCommand {
        guard let command = AdjacentElementSlot.inserting(.spanner(spanner), at: index, in: voice, of: score) else {
            throw refused(.targetNotFound(anchor), operation: "setSpanner")
        }
        return command
    }

    /// "Already there" is decided the way `apply` will find it later: for a chord-anchored kind, the anchor
    /// chord's own array; for a line kind, the attachment RUN before the anchor (§3.4's group-3 amendment); for a
    /// volta, the head of the canonical staff's bar. So a hairpin written by step N is found by step N+1 even
    /// though it shifted the chord's index.
    private static func refuseDuplicate(_ kind: Spanner.Kind, at anchor: VoiceElementID, in score: Score) throws {
        let found: Bool
        switch storage(of: kind) {
        case .chordAnchored:
            guard case let .chord(chord)? = score[anchor] else { return }
            found = chord.spanners.contains { $0.kind == kind }
        case .voiceElement:
            found = AdjacentElementSlot.find(.before, of: anchor, in: score) {
                if case let .spanner(existing) = $0 { existing.kind == kind } else { false }
            } != nil
        case .measureVolta:
            found = score[voice: VoiceRef(anchor)]?.elements.contains {
                if case let .spanner(existing) = $0 { existing.kind == kind } else { false }
            } ?? false
        }
        if found {
            throw refused(.duplicateSpanner(at: anchor, kind: kind), operation: "setSpanner")
        }
    }
}
