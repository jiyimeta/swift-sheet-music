import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// Encoding of the chord-anchored `<Spanner type="Slur">` pair — the
/// mirror of `SlurDecodeTests`.
@Suite("Chord-anchored slur round-trip")
struct SlurRoundTripTests {
    /// `slur_ms4_resave.mscx` is written in *this* package's writer dialect
    /// (2-space indent, self-closed empty leaves — see `XMLTreeSerializer`,
    /// whose header states byte parity with MuseScore Studio's own writer is
    /// a non-goal), so the file is a golden fixed point: decode → encode must
    /// reproduce it byte for byte.
    ///
    /// What it pins that no model-level check can is the *slot* and the
    /// *shape*: the begin `<Spanner type="Slur">` sits immediately after
    /// `<durationType>`, and the end chord carries a `<prev><location>` whose
    /// offsets are the negation of the begin side's `<next>`.
    @Test("the MS4-era fixture survives decode → encode byte-identically")
    func ms4FixtureIsByteStable() throws {
        let data = try MSCXFixtureLoader.mscxData("slur_ms4_resave")
        let score = try MSCXParser.parse(data)
        let encoded = try MSCXEncoder.encode(score)
        let written = try #require(String(bytes: encoded, encoding: .utf8))
        let onDisk = try #require(String(bytes: data, encoding: .utf8))
        #expect(written == onDisk)
    }

    /// MS3-native fixture: model-level round-trip stability (second pass
    /// equals first). Whole-file v3 byte parity is deliberately not a gate —
    /// the encoder normalizes unrelated MS3-era fields, exactly as
    /// `LegacyBendRoundTripTests` documents for its own fixtures.
    ///
    /// The two same-voice slurs are checked against MuseScore's own bytes:
    /// the re-encoded `<prev>` must sit on the chord MuseScore put it on and
    /// carry the values MuseScore wrote there. Nothing weaker would catch a
    /// marker that lands one chord early or late, since the slur *count* is
    /// blind to placement.
    @Test("the MS3 fixture reaches a fixed point with all three slurs intact")
    func ms3FixtureModelRoundTrips() throws {
        let score = try MSCXParser.parse(
            MSCXFixtureLoader.mscxData("slur_ms3_exchangevoices"),
        )
        let encoded = try MSCXEncoder.encode(score)
        let reDecoded = try MSCXParser.parse(encoded)
        let secondPass = try MSCXEncoder.encode(reDecoded)
        #expect(encoded == secondPass)
        #expect(Self.slurCount(in: score) == 3)
        #expect(Self.slurCount(in: reDecoded) == Self.slurCount(in: score))
        try Self.expectMS3EndMarkersMatchMuseScore(in: encoded)
    }

    /// The two same-voice slurs of `slur_ms3_exchangevoices.mscx`, asserted in
    /// the RE-ENCODED tree against the bytes MuseScore itself wrote.
    ///
    /// 1. Same-measure slur, begun on bar 1's first eighth
    ///    (`:89-97`, `<fractions>7/8`). MuseScore's `<prev>` is on bar 1's
    ///    **8th** eighth — the `pitch 72` chord — reading
    ///    `<fractions>-7/8</fractions>` (`:149-157`).
    /// 2. Barline-crossing slur, begun on bar 2's `half` at `1/2`
    ///    (`:200-211`, `<measures>1` + `<fractions>-1/2`). MuseScore's
    ///    `<prev>` is on bar 3's opening `half` — the `pitch 71` chord —
    ///    reading `<measures>-1</measures><fractions>1/2</fractions>`
    ///    (`:250-259`), measures-first, which is the order this encoder now
    ///    writes in every target version.
    ///
    /// The cross-voice slur is deliberately absent here: its `<prev>` legally
    /// moves voice, and `crossVoiceSlurEndStaysInItsOwnVoice` owns that case.
    private static func expectMS3EndMarkersMatchMuseScore(in encoded: Data) throws {
        let measures = try #require(
            XMLTreeParser.parse(encoded).first("Score")?
                .first("Staff")?.all("Measure"),
        )
        #expect(measures.count == 3)

        let bar1 = try #require(measures[0].first("voice")).all("Chord")
        #expect(bar1.count == 8)
        #expect(bar1[7].first("Note")?.first("pitch")?.text == "72")
        let sameMeasure = try #require(
            bar1[7].first("Spanner")?.first("prev")?.first("location"),
        )
        #expect(sameMeasure.children.map(\.name) == ["fractions"])
        #expect(sameMeasure.first("fractions")?.text == "-7/8")

        let bar3 = try #require(measures[2].first("voice")).all("Chord")
        #expect(bar3[0].first("Note")?.first("pitch")?.text == "71")
        let crossBarline = try #require(
            bar3[0].first("Spanner")?.first("prev")?.first("location"),
        )
        #expect(crossBarline.children.map(\.name) == ["measures", "fractions"])
        #expect(crossBarline.first("measures")?.text == "-1")
        #expect(crossBarline.first("fractions")?.text == "1/2")
    }

    /// The known limitation, pinned rather than left to be rediscovered.
    ///
    /// `slur_ms3_exchangevoices.mscx:221-230` holds a slur that hops voices —
    /// `<next><location><voices>-1</voices><fractions>1/4</fractions>`, begun
    /// in the second voice of bar 2 and ended in the first. `<voices>` is not
    /// modeled (`Spanner.decode` drops it) and this encoder walks one voice
    /// at a time, so the `<prev>` cannot be handed to the other voice's
    /// chord. What survives: the begin side keeps its own offsets, and the
    /// `<prev>` lands on the chord at the target position *within the same
    /// voice* — bar 2 voice 2's second quarter, not bar 2 voice 1's. Voice 1
    /// keeps only the marker of the slur that really is its own.
    @Test("a cross-voice slur keeps its begin side and re-homes its <prev>")
    func crossVoiceSlurEndStaysInItsOwnVoice() throws {
        let score = try MSCXParser.parse(
            MSCXFixtureLoader.mscxData("slur_ms3_exchangevoices"),
        )
        let tree = try XMLTreeParser.parse(MSCXEncoder.encode(score))
        let voices = try #require(
            tree.first("Score")?.first("Staff")?.all("Measure")[1].all("voice"),
        )
        #expect(voices.count == 2)
        let secondVoiceChords = voices[1].all("Chord")
        // Begin side intact, minus the unmodeled `<voices>`.
        #expect(secondVoiceChords[0].first("Spanner")?.first("next")?
            .first("location")?.first("fractions")?.text == "1/4")
        // …and its `<prev>` re-homed into the same voice.
        #expect(secondVoiceChords[1].first("Spanner")?.first("prev")?
            .first("location")?.first("fractions")?.text == "-1/4")
        // MuseScore had put that `<prev>` on voice 1's quarter at 1/4; the
        // only marker left there now is the one voice 1 owns itself.
        let firstVoiceChords = voices[0].all("Chord")
        #expect(firstVoiceChords[2].all("Spanner").isEmpty)
        #expect(firstVoiceChords[3].first("Spanner")?.children.map(\.name)
            == ["Slur", "next"])
    }

    /// The begin marker's slot. MuseScore's `TWrite::writeProperties(const
    /// ChordRest*, …)` (`rw/write/twrite.cpp:1093`) writes `<durationType>`
    /// and then, at its tail, the slur-spanner loop (`:1135`) — everything
    /// `TWrite::write(const Chord*, …)` adds (articulations, notes) comes
    /// after. Both vendored fixtures show the pair right behind
    /// `<durationType>`; moving the emission fails this test.
    @Test("the begin marker follows <durationType>")
    func beginMarkerSlotFollowsDurationType() {
        var chord = Chord(duration: .half, notes: [Note(pitch: 60, tpc: 14)])
        chord.articulations = [ChordArticulation(kind: .staccato)]
        chord.spanners = [Self.slur(fractions: Fraction(numerator: 1, denominator: 2))]
        let node = chord.encodeAsChord()
        #expect(node.children.map(\.name)
            == ["durationType", "Spanner", "Articulation", "Note"])
    }

    /// The begin marker's shape: `<Slur/>` payload plus `<next><location>`,
    /// exactly what the voice-level writer produces for the begin side of a
    /// spanner pair.
    @Test("the begin marker carries the <Slur> payload and its <next>")
    func beginMarkerCarriesPayloadAndNext() throws {
        var chord = Chord(duration: .half, notes: [Note(pitch: 60, tpc: 14)])
        chord.spanners = [Self.slur(fractions: Fraction(numerator: 1, denominator: 2))]
        let spanner = try #require(chord.encodeAsChord().first("Spanner"))
        #expect(spanner.attributes == ["type": "Slur"])
        #expect(spanner.children.map(\.name) == ["Slur", "next"])
        #expect(spanner.first("next")?.first("location")?
            .first("fractions")?.text == "1/2")
    }

    /// A slur whose begin side is marked invisible still writes its begin
    /// side, and writes the flag with it. `Spanner.encode` dispatches
    /// begin-vs-end on `visible` because a *voice-level* end side is modeled
    /// as an invisible spanner; a chord-anchored one never is —
    /// `Chord.spanners` holds begin sides only (the `<prev>`-only markers are
    /// dropped on decode and recomputed here), so `<visible>` means what it
    /// says and has to survive the write. `decodeVisible` reads it back off
    /// the `<Slur>` payload child, so that is where it goes.
    @Test("an invisible slur encodes as a begin side carrying <visible>0")
    func invisibleSlurStillEncodesTheBeginSide() throws {
        var slur = Self.slur(fractions: Fraction(numerator: 1, denominator: 2))
        slur.visible = false
        var chord = Chord(duration: .half, notes: [Note(pitch: 60, tpc: 14)])
        chord.spanners = [slur]
        let spanner = try #require(chord.encodeAsChord().first("Spanner"))
        #expect(spanner.children.map(\.name) == ["Slur", "next"])
        #expect(spanner.first("Slur")?.first("visible")?.text == "0")
        // …and comes back invisible rather than silently un-hidden.
        #expect(Chord.decodeChordSpanners(chord.encodeAsChord())
            .first?.visible == false)
    }

    /// The end marker is the negation of the begin offsets, in the
    /// `<location>` child order the target version uses. MuseScore's own
    /// `<prev>` for the MS3 fixture's barline-crossing slur — begin
    /// `<measures>1</measures><fractions>-1/2</fractions>` — is
    /// `<measures>-1</measures><fractions>1/2</fractions>`
    /// (`slur_ms3_exchangevoices.mscx:205-210` and `:252-259`).
    ///
    /// The shape is the fixture's own: a `half` chord starting at `1/2` of
    /// its bar slurred to the first chord of the next, so
    /// `fractions == 0 − 1/2`.
    @Test("a barline-crossing slur's <prev> negates both offsets")
    func crossBarlineEndMarkerNegatesBothOffsets() throws {
        let node = try Self.crossBarlineStaff().encodeTopLevel(
            staffID: "1", options: .init(targetVersion: .v3),
        )
        let endChord = try #require(
            node.all("Measure")[1].first("voice")?.all("Chord").first,
        )
        let location = try #require(
            endChord.first("Spanner")?.first("prev")?.first("location"),
        )
        #expect(location.children.map(\.name) == ["measures", "fractions"])
        #expect(location.first("measures")?.text == "-1")
        #expect(location.first("fractions")?.text == "1/2")
    }

    /// A same-measure slur's `<prev>` lands on the chord at the begin
    /// position plus the begin offset, and carries `<fractions>` only.
    @Test("a same-measure slur's <prev> lands on the offset chord")
    func sameMeasureEndMarkerLandsOnTheOffsetChord() throws {
        var head = Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])
        head.spanners = [Self.slur(fractions: Fraction(numerator: 1, denominator: 2))]
        let voice = Voice(elements: [
            .chord(head),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 62, tpc: 16)])),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 64, tpc: 18)])),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 65, tpc: 13)])),
        ])
        let chords = try voice.encode().all("Chord")
        #expect(chords.count == 4)
        #expect(chords[1].all("Spanner").isEmpty)
        let location = try #require(
            chords[2].first("Spanner")?.first("prev")?.first("location"),
        )
        #expect(location.children.map(\.name) == ["fractions"])
        #expect(location.first("fractions")?.text == "-1/2")
        #expect(chords[3].all("Spanner").isEmpty)
    }

    /// Same slur, v4 target: byte-for-byte the same pair. MuseScore has one
    /// `Location` writer, `<measures>` before `<fractions>` in both eras
    /// (3.6.2 `Location::write`, `libmscore/location.cpp:52-63`; master
    /// `TWrite::write(const Location*, …)`, `rw/write/twrite.cpp:2237-2238`),
    /// so this encoder no longer branches on the target version — see
    /// `Spanner.relativeLocationChildren`.
    @Test("the v4 export writes the identical pair, measures-first")
    func crossBarlineEndMarkerFollowsV4LocationOrder() throws {
        let staff = Self.crossBarlineStaff()
        let node = try staff.encodeTopLevel(
            staffID: "1", options: .init(targetVersion: .v4),
        )
        let beginLocation = try #require(
            node.all("Measure")[0].first("voice")?.all("Chord").last?
                .first("Spanner")?.first("next")?.first("location"),
        )
        #expect(beginLocation.children.map(\.name) == ["measures", "fractions"])
        let endLocation = try #require(
            node.all("Measure")[1].first("voice")?.all("Chord").first?
                .first("Spanner")?.first("prev")?.first("location"),
        )
        #expect(endLocation.children.map(\.name) == ["measures", "fractions"])
        #expect(endLocation.first("measures")?.text == "-1")
        #expect(endLocation.first("fractions")?.text == "1/2")
        // The two dialects now produce the identical staff.
        try #expect(node == staff.encodeTopLevel(
            staffID: "1", options: .init(targetVersion: .v3),
        ))
    }

    /// A chord that both ends one slur and begins another writes the end
    /// marker first. MuseScore walks `spannerMap().findOverlapping(…)`, whose
    /// interval tree is visited in start-tick order
    /// (`thirdparty/intervaltree/IntervalTree.h`, `visit_overlapping`), and a
    /// slur ending here necessarily started earlier than one beginning here.
    @Test("an end marker precedes a begin marker on the same chord")
    func endMarkerPrecedesBeginMarkerOnTheSameChord() throws {
        var head = Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])
        head.spanners = [Self.slur(fractions: Fraction(numerator: 1, denominator: 4))]
        var middle = Chord(duration: .quarter, notes: [Note(pitch: 62, tpc: 16)])
        middle.spanners = [Self.slur(fractions: Fraction(numerator: 1, denominator: 4))]
        let voice = Voice(elements: [
            .chord(head),
            .chord(middle),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 64, tpc: 18)])),
        ])
        let chords = try voice.encode().all("Chord")
        #expect(chords[1].children.map(\.name)
            == ["durationType", "Spanner", "Spanner", "Note"])
        let spanners = chords[1].all("Spanner")
        #expect(spanners[0].children.map(\.name) == ["prev"])
        #expect(spanners[1].children.map(\.name) == ["Slur", "next"])
    }

    /// A slur pointing past the end of the score drops its `<prev>` rather
    /// than crashing or emitting a marker on the wrong chord. Same
    /// non-crash convention the tie / guitar-bend location math uses for an
    /// endpoint the encoder cannot see.
    @Test("an unresolvable end marker is dropped, not fatal")
    func unresolvableEndMarkerIsDropped() throws {
        var head = Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])
        head.spanners = [Self.slur(measures: 9)]
        let voice = Voice(elements: [.chord(head)])
        let node = try voice.encode()
        let chords = node.all("Chord")
        #expect(chords.count == 1)
        // The begin side is untouched; only the unreachable marker is gone.
        #expect(chords[0].first("Spanner")?.children.map(\.name)
            == ["Slur", "next"])
    }

    /// A slur whose end lands on a rest gets its `<prev>` all the same:
    /// MuseScore anchors slurs to any `ChordRest` and writes both sides
    /// through the one `TWrite::writeProperties(const ChordRest*, …)`.
    @Test("an end marker lands on a rest too")
    func endMarkerLandsOnARest() throws {
        var head = Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])
        head.spanners = [Self.slur(fractions: Fraction(numerator: 1, denominator: 4))]
        let voice = Voice(elements: [
            .chord(head),
            .chord(Chord(duration: .quarter, notes: [])),
        ])
        let rest = try #require(voice.encode().first("Rest"))
        #expect(rest.children.map(\.name) == ["durationType", "Spanner"])
        #expect(rest.first("Spanner")?.first("prev")?
            .first("location")?.first("fractions")?.text == "-1/4")
    }

    // MARK: - Helpers

    /// Two measures echoing the MS3 fixture's barline-crossing slur: a `half`
    /// chord at `1/2` of bar 1 slurred to the first chord of bar 2, so the
    /// begin side is `measures 1` / `fractions -1/2`.
    private static func crossBarlineStaff() -> Staff {
        var head = Chord(duration: .half, notes: [Note(pitch: 74, tpc: 16)])
        head.spanners = [slur(
            measures: 1,
            fractions: Fraction(numerator: -1, denominator: 2),
        )]
        let voice = Voice(elements: [
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 62, tpc: 16)])),
            .chord(head),
        ])
        let follower = Voice(elements: [
            .chord(Chord(duration: .half, notes: [Note(pitch: 71, tpc: 19)])),
            .chord(Chord(duration: .half, notes: [])),
        ])
        return Staff(measures: [
            Measure(voices: [voice]), Measure(voices: [follower]),
        ])
    }

    private static func slur(
        measures: Int = 0, fractions: Fraction? = nil,
    ) -> Spanner {
        Spanner(
            kind: .slur, rawType: "Slur",
            nextMeasuresOffset: measures,
            nextFractionsOffset: fractions,
        )
    }

    /// Every chord-anchored slur in the score, in staff / measure / voice /
    /// element document order. Rests are note-less `Chord`s, so this walk
    /// covers them without a separate case — the same walk `SlurDecodeTests`
    /// uses.
    private static func slurCount(in score: Score) -> Int {
        score.allStaves.flatMap { _, staff in
            staff.measures.flatMap { measure in
                measure.voices.flatMap { voice in
                    voice.elements.flatMap { element -> [Spanner] in
                        guard case let .chord(chord) = element else { return [] }
                        return chord.spanners
                    }
                }
            }
        }
        .filter { $0.kind == .slur }
        .count
    }
}
