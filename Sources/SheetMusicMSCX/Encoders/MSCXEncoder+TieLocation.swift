import Foundation
import SheetMusicCore

/// Encoder-internal description of a Tie spanner's `<location>`
/// payload. MuseScore Studio interprets this in two distinct ways
/// depending on whether `<measures>` is present:
///
/// * `.sameMeasure(fractions:)` — emits `<location><fractions>F</fractions></location>`,
///   except when `F` is exactly `0/1` (`TieLocation.graceZeroDelta`), where the
///   `<fractions>` child itself is elided, matching MuseScore's own default-value
///   elision — see `graceZeroDelta`'s doc comment. MuseScore reads the fraction (present
///   or implied `0/1`) as a tick delta from the source position to the destination
///   position within the same measure.
///
/// * `.crossMeasure(measures:fractions:)` — emits
///   `<location><measures>M</measures><fractions>F</fractions></location>`
///   (fractions omitted when nil). MuseScore reads this as
///   `(measure delta, position-within-target-measure)`. The
///   `<measures>` token is what disambiguates "this tie crosses a
///   bar line" — without it, MuseScore matches the wrong chord on
///   the source side of the bar, which is what produced the
///   m21→m23 cross-wired ties in `test_export9.mscx`.
///
/// * `.graceIndexed(_:)` — emits `<location><grace>N</grace></location>`,
///   no `<fractions>`/`<measures>`. MuseScore reads `<grace>` as the
///   destination's ordinal within its parent chord's grace series
///   (`Location::graceIndex`, `dom/location.cpp:199-208`); see this
///   case's own doc comment below for the exact shape observed in a
///   genuine MuseScore Studio fixture (on a GuitarBend, not a Tie —
///   `Location` read/write is spanner-generic, so the shape carries
///   over) and its citation trail.
enum TieLocation {
    case sameMeasure(fractions: Fraction)
    case crossMeasure(measures: Int, fractions: Fraction?)
    /// A tie whose partner is a specific grace chord of the *same*
    /// parent chord — emits `<location><grace>N</grace></location>`,
    /// no `<fractions>`/`<measures>` (both are zero and elided, same
    /// as `graceZeroDelta`). `N` is the grace chord's 0-based ordinal
    /// within its parent's combined before+after grace series — see
    /// `Chord.graceBeforeTieBackLocations()`'s doc comment for how
    /// that ordinal is derived and its caveats.
    case graceIndexed(Int)

    /// The location for a grace note's own tie into/from a note of its
    /// parent chord — the single most common grace tie, e.g. a tied
    /// acciaccatura into its main note. Used by `GraceChord.encode`
    /// for the grace note's *own* `<next>`/`<prev>`, whose partner (an
    /// ordinary note of the parent chord) is never itself a grace, so
    /// no `<grace>` tag is needed — see `.graceIndexed` for the mirror
    /// case, where the partner *is* the grace chord.
    ///
    /// A grace chord shares its parent chord's tick — MuseScore's
    /// writer never advances the cursor for a grace item
    /// (`if (!item->isGrace()) { … ctx.incCurTick(t); }`,
    /// `rw/write/twrite.cpp:1127-1133`) because `EngravingItem::tick()`
    /// (`dom/engravingitem.cpp:584-596`) resolves through the enclosing
    /// `Segment`, which a grace chord shares with the chord it
    /// decorates. So the tie's source and destination ticks are
    /// identical: zero delta, same measure.
    ///
    /// This is `.sameMeasure(fractions: 0/1)` rather than a distinct
    /// case because MuseScore's own `SpannerWriter`
    /// (`rw/write/connectorinfowriter.cpp:103-139`,
    /// `SpannerWriter::SpannerWriter`) prefers computing a tie's
    /// `<location>` from its actual start/end elements via
    /// `Location::fillForElement` (`dom/location.cpp:128-139`) over any
    /// tie-specific special-casing — reusing the ordinary same-measure
    /// path is what "prefer this source of information" means in
    /// practice for a grace tie. (`ConnectorInfo::connect`, the actual
    /// endpoint-matching comparison this location feeds, lives at
    /// `dom/connector.cpp:91-122` — a different file from the writer
    /// despite the similar name.)
    ///
    /// Verified this is not merely a formatting nicety: MuseScore's
    /// reader treats an *absent* `<location>` under `<next>`/`<prev>`
    /// as "position unknown" (`ConnectorInfoReader::readEndpointLocation`,
    /// `rw/read460/connectorinforeader.cpp:120-132`, leaves the
    /// `Location` at its `measure == INT_MIN` sentinel when no
    /// `<location>` child is present), and `hasNext()` / `hasPrevious()`
    /// (`dom/connector.h:69-70`) test exactly that sentinel. A
    /// location-less `<next/>` therefore makes both `isStart()` and
    /// `isEnd()` false, so `ConnectorInfoReader::readAddConnector(Note*,
    /// …)` (`rw/read460/connectorinforeader.cpp:365-425`) never wires
    /// the parsed `Tie` object to a start/end note at all — the tie is
    /// silently dropped on reload by MuseScore Studio. Emitting an
    /// explicit (even all-zero) `<location>` is what keeps `hasNext()`
    /// true (`Location::relative()` defaults `measure` to `0`, not
    /// `INT_MIN` — `dom/location.h:51`), so the grace note's tie
    /// reconnects correctly.
    static let graceZeroDelta = TieLocation.sameMeasure(
        fractions: Fraction(numerator: 0, denominator: 1),
    )
}

/// One end of a `<Spanner type="Tie">` — everything the `<location>`
/// under `<next>` / `<prev>` has to say about where the partner note
/// sits, which is two independent things:
///
/// * **`location`** — the positional half (measure / fraction delta, or
///   the partner grace's ordinal).
/// * **`notesDelta`** — `<notes>`, which selects *which note of that
///   chord*: `Location::note(partner) − Location::note(self)`
///   (`Location::note`, `dom/location.cpp:214-231`; see
///   `MSCXLocationNoteIndex`).
///
/// The two halves are relativized differently, which is why they can't
/// collapse into one case payload. `Location::toRelative`
/// (`dom/location.cpp:82-93`) subtracts `m_note` but leaves
/// `m_graceIndex` alone, and `toAbsolute` (`:65-76`) mirrors that. So
/// `<grace>` is written and read as an **absolute** ordinal while
/// `<notes>` is a **delta** between the two endpoints — and the final
/// comparison, `Location::operator==` via `ConnectorInfo::connect`
/// (`dom/connector.cpp:91-122`), tests both fields, so a wrong
/// `<notes>` silently drops the tie exactly as a missing `<location>`
/// would.
///
/// Zero is the default and is elided, matching
/// `xml.tag("notes", item->note(), relDefaults.note())` with
/// `relDefaults.note() == 0` (`TWrite::write(const Location*, …)`,
/// `rw/write/twrite.cpp:2229-2243`; `Location::relative()`,
/// `dom/location.h:51`). Both tied notes being alone in their chords is
/// therefore the case that already worked before `<notes>` existed
/// here — `Location::note` special-cases `notes.size() == 1` to `0`, so
/// the comparison was a correct `0 − 0`.
struct TieEndpoint {
    var location: TieLocation
    var notesDelta: Int

    init(_ location: TieLocation, notesDelta: Int = 0) {
        self.location = location
        self.notesDelta = notesDelta
    }
}
