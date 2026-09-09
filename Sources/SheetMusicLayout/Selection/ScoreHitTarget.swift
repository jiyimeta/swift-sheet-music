import SheetMusicCore

/// The engraving element sitting under a point during a hit-test.
///
/// `ScoreHitTester.hitTest(at:)` returns one of these. The library
/// does not dictate what a click "means" — it just reports what was
/// hit, so the app can decide its own selection / interaction policy
/// (MuseScore-style beam-length editing, "clicking the stem selects
/// the note", "clicking the beam selects the run", etc.).
///
/// For `.stem`, `.flag`, and `.beam`, the associated `notes` array
/// lists every notehead that shares the stem / flag / beam run. For
/// a chord this is all of its notes; for a beam run it is every
/// notehead on every chord under that beam.
///
/// ## The priority ladder — first match wins
///
/// `ScoreHitTester.hitTest(at:)` tries, in order:
///
/// **notehead → rest → beam → flag → stem → tuplet → clef → text.**
///
/// This is the one place that order is written down; `hitTest`'s own doc points here, because the copy it
/// used to carry went stale. Each rung earns its position: beam precedes stem so a click on the beam bar
/// resolves to `.beam` rather than the stem endpoint beneath it, and flag precedes stem so the flag curve
/// resolves to `.flag` rather than the stem it sits on top of. Tuplet is late so a click on a notehead
/// inside the bracket still selects the note, and clef is later still (its header column overlaps no note
/// geometry, so its position is mostly cosmetic).
///
/// ## Engraved text is tried LAST
///
/// Engraved text targets are reported only after every preceding rung has declined the
/// point, so a syllable can never steal a click that is plainly on a note.
///
/// How much that ordering currently buys was measured rather than assumed, and the answer is: nothing yet,
/// by a hair. The skyline leaves the lyric line a constant **2.6 sp** below the lowest notehead — at every
/// pitch and staff size tried, since both distances scale with the spatium — against a combined reach of
/// 1.2 sp (the notehead's hit radius) + 1 sp (half a syllable's box) + 0.25 sp
/// (`ScoreHitTester.textHitTolerance`) = **2.45 sp**. The stem-down case clears by less still, about 0.1 sp.
/// So under today's autoplace no point in a laid-out score is claimed by both passes, and the ordering is
/// defence-in-depth: any change to those clearances, to the hit tolerances, or to the lyrics font puts them
/// in contact. `ScoreHitTesterTextTests` pins both halves — the disjointness in a real layout, and the
/// ordering itself against a synthetic overlap, since a real one cannot currently be produced.
///
/// Each text case carries the identity the layout element already holds, so a hit round-trips back to the
/// command that edits it: `SetLyric` takes the `anchor` + `verse`, `SetStaffText` the `anchor` + `style`,
/// `SetChordSymbol` the `anchor`, and `SetRehearsalMark` the `measureIndex` (a rehearsal mark is a system
/// element addressed by bar, so it has no voice element to name). Text whose layout element carries no
/// identity is not reported at all: an instrument-change instruction and a `<Swing>` marking reach the page
/// through `.staffText` but no text-entry command can address them.
public enum ScoreHitTarget: Hashable, Sendable {
    case note(NoteID)
    case rest(RestID)
    case stem(notes: [NoteID])
    case flag(notes: [NoteID])
    case beam(notes: [NoteID])
    /// Tuplet bracket / number area. Hit-target for clicking the
    /// "3" / "5" label or the bracket line that spans the tuplet.
    case tuplet(TupletID)
    /// Selectable clef glyph. Only emitted for clefs whose
    /// `LayoutElement.clef.anchor` is non-nil — continuation-system
    /// header clef restatements are not hit-targets.
    case clef(ClefAnchor)
    /// An engraved lyric syllable. `anchor` is the chord that owns it, `verse` its lyric-array index — the
    /// two arguments `SetLyric` takes.
    case lyric(anchor: VoiceElementID, verse: Int)
    /// Free-form staff or system text. The two are ONE layout case separated by `style`, and a host needs to
    /// know which it clicked to open the right kind of caret, so the style travels with the target.
    case staffText(anchor: VoiceElementID, style: TextStyleType)
    /// A chord symbol. `anchor` is the chord or rest the symbol names, not the harmony element's own index.
    case harmony(anchor: VoiceElementID)
    /// A rehearsal mark, including its frame: the box is what a reader aims at, and a click on the border of
    /// a boxed "A" means the mark. Addressed by bar, like `SetRehearsalMark`.
    case rehearsalMark(measureIndex: Int)
    /// A dynamic marking, addressed by `SetDynamic`. See `ScoreElementID.dynamic` for its address semantics.
    case dynamic(anchor: VoiceElementID)
    /// A fermata, addressed by `SetFermata`. See `ScoreElementID.fermata` for its address semantics.
    case fermata(anchor: VoiceElementID)
    /// A breath mark, addressed by `SetBreath`. See `ScoreElementID.breath` for its address semantics.
    case breath(anchor: VoiceElementID)
    /// A tempo marking, addressed by `SetTempo`. See `ScoreElementID.tempo` for its address semantics.
    case tempo(anchor: VoiceElementID)
    /// A spanner identified by its anchor and kind for `RemoveSpanner`. See `ScoreElementID.spanner`.
    case spanner(anchor: VoiceElementID, kind: Spanner.Kind)
    /// A bar's key signature, addressed by `SetKeySignature`. See `ScoreElementID.keySignature` for its scope.
    case keySignature(measureIndex: Int)
    /// A bar's meter, addressed by `SetTimeSignature`. See `ScoreElementID.timeSignature` for the re-bar scope.
    case timeSignature(measureIndex: Int)
    /// A barline: explicit and trailing roles feed `SetBarLine`, start-repeat feeds `SetRepeatBarLines`.
    /// See `ScoreElementID.barLine` for its address semantics.
    case barLine(measureIndex: Int, role: BarLineRole)
    /// An owning chord's articulation kind, addressed by `SetArticulation`. See `ScoreElementID.articulation`.
    case articulation(anchor: VoiceElementID, kind: ChordArticulation.Kind)
}

extension ScoreHitTarget {
    /// The target that reports `id`. The inverse of `textID`, and the only way a text target is built from
    /// a layout element — see `LayoutElement.textID`.
    public init(textID id: ScoreTextID) {
        switch id {
        case let .lyric(anchor, verse):
            self = .lyric(anchor: anchor, verse: verse)
        case let .staffText(anchor, style):
            self = .staffText(anchor: anchor, style: style)
        case let .harmony(anchor):
            self = .harmony(anchor: anchor)
        case let .rehearsalMark(measureIndex):
            self = .rehearsalMark(measureIndex: measureIndex)
        }
    }

    /// This target's text identity. Non-text targets report `nil`.
    ///
    /// A straight re-wrap: `ScoreTextID` carries the text cases with matching labels and
    /// payloads, so a host turning a hit into a selection does not need a translation table, and cannot
    /// invent an identity the editing commands would not recognise.
    public var textID: ScoreTextID? {
        switch self {
        case let .lyric(anchor, verse):
            return .lyric(anchor: anchor, verse: verse)
        case let .staffText(anchor, style):
            return .staffText(anchor: anchor, style: style)
        case let .harmony(anchor):
            return .harmony(anchor: anchor)
        case let .rehearsalMark(measureIndex):
            return .rehearsalMark(measureIndex: measureIndex)
        case .note, .rest, .stem, .flag, .beam, .tuplet, .clef:
            return nil
        case .dynamic, .fermata, .breath, .tempo, .spanner, .keySignature, .timeSignature, .barLine, .articulation:
            return nil
        }
    }

    /// The selectable item a click on this target names, including text and engraved elements — the total map
    /// `LayoutDocument.editingHitTest` deliberately does not perform.
    ///
    /// `editingHitTest` drops text, clefs and engraved elements because the meaning of a click is host policy;
    /// see `selectableItem(from:)`. This property is the other half a host needs once it has decided that
    /// policy: it answers for every target, so `hitTest(at:)` → `ScoreSelection.single` is one step.
    /// `.stem` / `.flag` / `.beam` resolve to the first notehead they carry, as they do there.
    public var selectableItem: ScoreItemID? {
        switch self {
        case let .note(id): return .note(id)
        case let .rest(id): return .rest(id)
        case let .tuplet(id): return .tuplet(id)
        case let .clef(anchor): return .clef(anchor)
        case let .stem(notes), let .flag(notes), let .beam(notes):
            return notes.first.map(ScoreItemID.note)
        case .lyric, .staffText, .harmony, .rehearsalMark:
            return textID.map(ScoreItemID.text)
        case .dynamic, .fermata, .breath, .tempo, .spanner, .keySignature, .timeSignature, .barLine, .articulation:
            return elementID.map(ScoreItemID.element)
        }
    }

    /// Re-wraps an element identity without changing its address or kind.
    public init(elementID id: ScoreElementID) {
        switch id {
        case let .dynamic(anchor):
            self = .dynamic(anchor: anchor)
        case let .fermata(anchor):
            self = .fermata(anchor: anchor)
        case let .breath(anchor):
            self = .breath(anchor: anchor)
        case let .tempo(anchor):
            self = .tempo(anchor: anchor)
        case let .spanner(anchor, kind):
            self = .spanner(anchor: anchor, kind: kind)
        case let .keySignature(measureIndex):
            self = .keySignature(measureIndex: measureIndex)
        case let .timeSignature(measureIndex):
            self = .timeSignature(measureIndex: measureIndex)
        case let .barLine(measureIndex, role):
            self = .barLine(measureIndex: measureIndex, role: role)
        case let .articulation(anchor, kind):
            self = .articulation(anchor: anchor, kind: kind)
        }
    }

    /// This target's element identity. Targets outside the engraved-element vocabulary report `nil`.
    public var elementID: ScoreElementID? {
        switch self {
        case let .dynamic(anchor):
            return .dynamic(anchor: anchor)
        case let .fermata(anchor):
            return .fermata(anchor: anchor)
        case let .breath(anchor):
            return .breath(anchor: anchor)
        case let .tempo(anchor):
            return .tempo(anchor: anchor)
        case let .spanner(anchor, kind):
            return .spanner(anchor: anchor, kind: kind)
        case let .keySignature(measureIndex):
            return .keySignature(measureIndex: measureIndex)
        case let .timeSignature(measureIndex):
            return .timeSignature(measureIndex: measureIndex)
        case let .barLine(measureIndex, role):
            return .barLine(measureIndex: measureIndex, role: role)
        case let .articulation(anchor, kind):
            return .articulation(anchor: anchor, kind: kind)
        case .note, .rest, .stem, .flag, .beam, .tuplet, .clef,
             .lyric, .staffText, .harmony, .rehearsalMark:
            return nil
        }
    }
}
