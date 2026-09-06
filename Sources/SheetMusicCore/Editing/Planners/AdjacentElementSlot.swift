import SheetMusicFoundation

/// Find / insert / replace / remove of a NON-TIMED element that attaches to a chord or rest by adjacency in the
/// voice stream (spec 2026-09-02 §3.1, "Adjacent attachments") — the placement MSCX uses and the decoder keeps
/// (`MSCXDecoder+Voice.swift`, which appends voice children in file order): annotations and spanner begins BEFORE
/// the `<Chord>` (`twrite.cpp:3527-3575` vs `:3596`), a clef / key / time of the same tick ahead of those
/// (`segment.h:41-58`), a breath AFTER the chord it follows (`Breath.swift`).
///
/// "Immediately before" is a RUN, not `index - 1`: the maximal stretch of annotation and signature elements
/// ending at the chord (after it: the stretch of breaths); the element a command wants is picked by predicate from
/// the whole run. A chord, a barline, a measure repeat or a `.locationShift` (which moves the cursor) ends it.
/// An insertion lands nearest the chord (`insertionIndex`); MuseScore's reader re-homes elements by tick, so the
/// order inside a run is this package's own convention. `SetClef` picks its own index (its segment precedes the
/// annotations').
///
/// A run never crosses a bar line, so a clef MuseScore wrote at the END of a bar — the placement that means "this
/// applies to the next bar" — belongs to no run: the next bar's first chord cannot see it. A documented v1 limit.
///
/// Every mutation returns a command: an insert or a remove changes element indices and so is a voice-level
/// `ReplaceVoiceElements`, whose inverse restores the indices exactly; a replace-in-place is a
/// `ReplaceVoiceElement`. Tuplet ranges are remapped through `MeasureStructure.remapTuplets`.
enum AdjacentElementSlot {
    enum Side {
        case before
        case after
    }

    /// Dynamics, fermatas, harmonies, sticking, expression text, capos, string tunings, figured bass, symbols,
    /// fret diagrams, and spanner begins: what MuseScore writes as a segment's annotations.
    static func isAnnotation(_ element: VoiceElement) -> Bool {
        switch element {
        case .dynamic, .fermata, .harmony, .sticking, .expression, .capo, .stringTunings, .figuredBass, .symbol,
             .fretDiagram, .spanner: true
        default: false
        }
    }

    /// Indices of the attachment run on `side` of the timed element at `anchor`. Empty when there is none.
    static func run(_ side: Side, of anchor: Int, in elements: [VoiceElement]) -> Range<Int> {
        switch side {
        case .before:
            var start = anchor
            while start > 0,
                  isAnnotation(elements[start - 1]) || MeasureStructure.isLeadingSignature(elements[start - 1])
            {
                start -= 1
            }
            return start ..< anchor
        case .after:
            var end = anchor + 1
            while end < elements.count, case .breath = elements[end] {
                end += 1
            }
            return (anchor + 1) ..< end
        }
    }

    /// Index of the first element in the run on `side` of `anchor` that `matches`, or `nil` — also `nil` when
    /// `anchor` does not name a chord or rest, since only a timed element has a run. (A rest IS a `.chord` with
    /// no notes; see `VoiceElement`.)
    static func find(
        _ side: Side, of anchor: VoiceElementID, in score: Score, where matches: (VoiceElement) -> Bool,
    ) -> Int? {
        guard let elements = score[voice: VoiceRef(anchor)]?.elements,
              elements.indices.contains(anchor.elementIndex),
              case .chord = elements[anchor.elementIndex]
        else { return nil }
        return run(side, of: anchor.elementIndex, in: elements).first { matches(elements[$0]) }
    }

    /// Where an insertion nearest the timed element at `anchor` lands.
    static func insertionIndex(_ side: Side, of anchor: Int) -> Int {
        side == .before ? anchor : anchor + 1
    }

    /// The voice rewritten with `element` at `index`, tuplets remapped; `nil` when the voice or index does not
    /// exist (`index == count` appends).
    static func inserting(
        _ element: VoiceElement, at index: Int, in ref: VoiceRef, of score: Score,
    ) -> ReplaceVoiceElements? {
        guard let voice = score[voice: ref], (0 ... voice.elements.count).contains(index) else { return nil }
        var elements = voice.elements
        elements.insert(element, at: index)
        return ReplaceVoiceElements(
            staff: ref.staff, measureIndex: ref.measureIndex, voiceIndex: ref.voiceIndex,
            elements: elements, tuplets: MeasureStructure.remapTuplets(voice.tuplets, insertingAt: index),
        )
    }

    static func replacing(_ element: VoiceElement, at index: Int, in ref: VoiceRef) -> ReplaceVoiceElement {
        ReplaceVoiceElement(
            at: VoiceElementID(
                staff: ref.staff, measureIndex: ref.measureIndex, voiceIndex: ref.voiceIndex, elementIndex: index,
            ),
            with: element,
        )
    }

    /// The voice rewritten without the element at `index`, tuplets remapped; `nil` when there is no such element.
    static func removing(at index: Int, in ref: VoiceRef, of score: Score) -> ReplaceVoiceElements? {
        guard let voice = score[voice: ref], voice.elements.indices.contains(index) else { return nil }
        var elements = voice.elements
        elements.remove(at: index)
        return ReplaceVoiceElements(
            staff: ref.staff, measureIndex: ref.measureIndex, voiceIndex: ref.voiceIndex,
            elements: elements, tuplets: MeasureStructure.remapTuplets(voice.tuplets, removingAt: index),
        )
    }
}
