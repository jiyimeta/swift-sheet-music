#if os(macOS)
import CoreGraphics
import SheetMusicCore
@testable import SheetMusicLayout
@testable import SheetMusicUI
import Testing

/// Cross-staff horizontal alignment: notes at the same tick should land
/// at the same x regardless of which staff or voice they live in.
/// Mirrors MuseScore's Segment concept — see
/// `LayoutEngine.tickColumns` for the algorithm.
@Suite("Cross-staff alignment")
struct MultiStaffAlignmentTests {

    @Test("Different-rhythm staves align on shared ticks (8+16+16 vs dotted8+16)")
    func alignsAcrossStavesWithDifferentRhythms() throws {
        guard #available(macOS 15.0, *) else { return }

        // Staff 1: 8th + 16th + 16th (ticks 0, 240, 360 at division 480)
        let c4 = Note(pitch: 60, tpc: 14)
        let d4 = Note(pitch: 62, tpc: 16)
        let e4 = Note(pitch: 64, tpc: 18)
        let rh = Measure(voices: [Voice(elements: [
            .clef(Clef(concertClefType: "G")),
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .chord(Chord(duration: .eighth,    notes: [c4])),
            .chord(Chord(duration: .sixteenth, notes: [d4])),
            .chord(Chord(duration: .sixteenth, notes: [e4])),
        ])])

        // Staff 2: dotted 8th + 16th (ticks 0, 360) — same beat
        // duration, fewer notes, so voice-local weight-cumulative
        // placement would put the 16th at a DIFFERENT fraction than
        // staff 1 expects.
        let c3 = Note(pitch: 48, tpc: 14)
        let e3 = Note(pitch: 52, tpc: 18)
        let lh = Measure(voices: [Voice(elements: [
            .clef(Clef(concertClefType: "F")),
            .chord(Chord(
                duration: NoteDuration.eighth.dotted(1),
                notes: [c3])),
            .chord(Chord(duration: .sixteenth, notes: [e3])),
        ])])

        let part = Part(
            id: "P1",
            trackName: "Piano",
            instrument: Instrument(
                id: "pno", longName: "Piano", shortName: "Pno."))
        let score = Score(
            division: 480,
            parts: [part],
            staves: [
                StaffContent(id: 1, measures: [rh]),
                StaffContent(id: 2, measures: [lh]),
            ])

        let doc = LayoutEngine.layout(
            score: score,
            options: .init(wrapToViewWidth: false),
            availableWidth: 900)

        let system = try #require(doc.systems.first)
        let measure = try #require(system.measures.first)

        // Chord elements in system order, grouped by staff: staff 1
        // emits first (3 chords), staff 2 second (2 chords).
        var chords: [(y: CGFloat, x: CGFloat)] = []
        for el in measure.elements {
            if case .chord(_, _, _, let so, _, _, _, _) = el {
                chords.append((y: so.y, x: so.x))
            }
        }
        try #require(chords.count == 5,
            "expected 5 chord emissions across both staves")

        // Split by y: staff 1 sits above staff 2, so the 3 lowest-y
        // entries belong to staff 1 and the 2 highest-y to staff 2.
        let sortedByY = chords.sorted { $0.y < $1.y }
        let staff1Xs = sortedByY.prefix(3).map(\.x).sorted()
        let staff2Xs = sortedByY.suffix(2).map(\.x).sorted()

        // Staff 1 ticks: 0, 240, 360 → xs[0], xs[1], xs[2].
        // Staff 2 ticks: 0, 360 → xs[0], xs[1].
        // Shared ticks (0 and 360) must share the same x.
        let tolerance: CGFloat = 0.5
        #expect(abs(staff1Xs[0] - staff2Xs[0]) < tolerance,
            "tick 0 x mismatch: staff1=\(staff1Xs[0]) staff2=\(staff2Xs[0])")
        #expect(abs(staff1Xs[2] - staff2Xs[1]) < tolerance,
            "tick 360 x mismatch: staff1=\(staff1Xs[2]) staff2=\(staff2Xs[1])")
    }

    @Test("Chord and rest at the same tick in different voices share one x")
    func chordRestSameTickShareX() throws {
        guard #available(macOS 15.0, *) else { return }
        // Voice 0: 4 quarter notes.  Voice 1: quarter + quarter rest +
        // quarter + quarter rest.  At every beat the rest (voice 1)
        // shares a tick with a note (voice 0); both must land at the
        // same x so the flag-shift bug can't resurrect.
        let c4 = Note(pitch: 60, tpc: 14)
        let v0: [VoiceElement] = [
            .clef(Clef(concertClefType: "G")),
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .chord(Chord(duration: .quarter, notes: [c4])),
            .chord(Chord(duration: .quarter, notes: [c4])),
            .chord(Chord(duration: .quarter, notes: [c4])),
            .chord(Chord(duration: .quarter, notes: [c4])),
        ]
        let v1: [VoiceElement] = [
            .chord(Chord(duration: .quarter, notes: [c4])),
            .rest(Rest(duration: .quarter)),
            .chord(Chord(duration: .quarter, notes: [c4])),
            .rest(Rest(duration: .quarter)),
        ]
        let m = Measure(voices: [
            Voice(elements: v0),
            Voice(elements: v1),
        ])
        let staff = StaffContent(id: 1, measures: [m])
        let score = Score(
            division: 480,
            parts: [Part(
                id: "P1", trackName: nil,
                instrument: Instrument(
                    id: "pno", longName: "Treble", shortName: "Tr."))],
            staves: [staff])
        let doc = LayoutEngine.layout(
            score: score,
            options: .init(wrapToViewWidth: false),
            availableWidth: 900)
        let measure = try #require(doc.systems.first?.measures.first)

        // Voice 0 chord xs, in emission order (ticks 0, 480, 960, 1440).
        var v0Xs: [CGFloat] = []
        var v1Xs: [CGFloat] = []  // voice 1 chord xs (ticks 0, 960)
        var v1RestXs: [CGFloat] = []  // voice 1 rest xs (ticks 480, 1440)
        var sawFirstChord = false
        var voice0Count = 0
        for el in measure.elements {
            switch el {
            case .chord(_, _, _, let so, _, _, _, _):
                if voice0Count < 4 {
                    v0Xs.append(so.x)
                    voice0Count += 1
                } else {
                    v1Xs.append(so.x)
                }
                sawFirstChord = true
            case .rest(_, let origin, _, _, _):
                if sawFirstChord {
                    v1RestXs.append(origin.x)
                }
            default:
                break
            }
        }

        try #require(v0Xs.count == 4)
        try #require(v1Xs.count == 2)
        try #require(v1RestXs.count == 2)

        let tol: CGFloat = 0.01
        // Tick 0 & 960: chord (v0) and chord (v1) → same x.
        #expect(abs(v0Xs[0] - v1Xs[0]) < tol)
        #expect(abs(v0Xs[2] - v1Xs[1]) < tol)
        // Tick 480 & 1440: chord (v0) and rest (v1) → same x (this
        // is the property the flag-shift used to break).
        #expect(abs(v0Xs[1] - v1RestXs[0]) < tol,
            "tick 480: v0 chord x=\(v0Xs[1]), v1 rest x=\(v1RestXs[0])")
        #expect(abs(v0Xs[3] - v1RestXs[1]) < tol,
            "tick 1440: v0 chord x=\(v0Xs[3]), v1 rest x=\(v1RestXs[1])")
    }

    @Test("Voice-1 whole rest centers in the measure, even alongside voice-0 melody")
    func multiVoiceWholeRestCentersInMeasure() throws {
        guard #available(macOS 15.0, *) else { return }
        let c4 = Note(pitch: 60, tpc: 14)
        let m = Measure(voices: [
            Voice(elements: [
                .clef(Clef(concertClefType: "G")),
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                .chord(Chord(duration: .quarter, notes: [c4])),
                .chord(Chord(duration: .quarter, notes: [c4])),
                .chord(Chord(duration: .quarter, notes: [c4])),
                .chord(Chord(duration: .quarter, notes: [c4])),
            ]),
            Voice(elements: [
                .rest(Rest(duration: .whole)),
            ]),
        ])
        let staff = StaffContent(id: 1, measures: [m])
        let score = Score(
            division: 480,
            parts: [Part(
                id: "P1", trackName: nil,
                instrument: Instrument(
                    id: "pno", longName: "Treble", shortName: "Tr."))],
            staves: [staff])
        let doc = LayoutEngine.layout(
            score: score,
            options: .init(wrapToViewWidth: false),
            availableWidth: 900)
        let measure = try #require(doc.systems.first?.measures.first)

        var v0Xs: [CGFloat] = []
        var wholeRestX: CGFloat?
        for el in measure.elements {
            switch el {
            case .chord(_, _, _, let so, _, _, _, _):
                v0Xs.append(so.x)
            case .rest(let dur, let origin, _, _, _):
                if case .whole = dur {
                    wholeRestX = origin.x
                }
            default:
                break
            }
        }

        try #require(v0Xs.count == 4)
        let wr = try #require(wholeRestX,
            "whole rest not found in emission list")

        // The whole rest must NOT share x with voice 0's first chord
        // — it's centered in the measure body (MuseScore behaviour),
        // distinct from tick 0 even when other voices carry content.
        // 3 pt is enough headroom to be unambiguous after we tightened
        // measure padding to match MuseScore's `Sid::measureSpacing`
        // defaults; the meaningful invariant is the upper-bound check
        // below.
        #expect(abs(wr - v0Xs[0]) > 3,
            "whole rest x=\(wr) should NOT match v0 tick-0 x=\(v0Xs[0])")
        // And it should land somewhere inside the measure's chord
        // span — i.e. between the first and last v0 chord. The
        // exact x depends on `Sid::measureSpacing` and the
        // proportional chord-to-chord weights; we don't pin it
        // precisely so future spacing tuning doesn't churn this
        // test.
        #expect(wr > v0Xs[0] && wr < v0Xs[3])
    }

    @Test("User repro: staves with different rhythms keep x monotonic at every tick")
    func userReproMonotonic() throws {
        guard #available(macOS 15.0, *) else { return }
        let c4 = Note(pitch: 60, tpc: 14)
        // Staff 1 — half + 7×16th (mixed rest/note/rest).
        let s1: [VoiceElement] = [
            .clef(Clef(concertClefType: "G")),
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .rest(Rest(duration: .half)),
            .rest(Rest(duration: .sixteenth)),
            .chord(Chord(duration: .sixteenth, notes: [c4])),
            .chord(Chord(duration: .sixteenth, notes: [c4])),
            .rest(Rest(duration: .sixteenth)),
            .rest(Rest(duration: .sixteenth)),
            .rest(Rest(duration: .sixteenth)),
            .rest(Rest(duration: .sixteenth)),
            .rest(Rest(duration: .sixteenth)),
        ]
        // Staff 2 — half + 16th rest + 16th + 8th rest + dotted 8th +
        // 16th rest.  Fewer elements ⇒ smaller voice total; with the
        // old max-of-voice-fractions algorithm this inflated staff
        // 2's fractions and pushed staff 1's tick-only ticks (1320,
        // 1560, 1680) LEFT of tick 1200, causing trailing rests to
        // pile up at the same x.
        let s2: [VoiceElement] = [
            .clef(Clef(concertClefType: "G")),
            .rest(Rest(duration: .half)),
            .rest(Rest(duration: .sixteenth)),
            .chord(Chord(duration: .sixteenth, notes: [c4])),
            .rest(Rest(duration: .eighth)),
            .chord(Chord(
                duration: NoteDuration.eighth.dotted(1),
                notes: [c4])),
            .rest(Rest(duration: .sixteenth)),
        ]
        let part = Part(
            id: "P1", trackName: "Duo",
            instrument: Instrument(
                id: "x", longName: "Duo", shortName: "D."))
        let score = Score(
            division: 480,
            parts: [part],
            staves: [
                StaffContent(id: 1, measures: [
                    Measure(voices: [Voice(elements: s1)])]),
                StaffContent(id: 2, measures: [
                    Measure(voices: [Voice(elements: s2)])]),
            ])
        let doc = LayoutEngine.layout(
            score: score,
            options: .init(wrapToViewWidth: false),
            availableWidth: 1200)
        let measure = try #require(doc.systems.first?.measures.first)

        // Collect (y, x) for every rest and chord emitted.
        struct Emit { let y: CGFloat; let x: CGFloat }
        var rows: [Emit] = []
        for el in measure.elements {
            switch el {
            case .chord(_, _, _, let so, _, _, _, _):
                rows.append(Emit(y: so.y, x: so.x))
            case .rest(_, let origin, _, _, _):
                rows.append(Emit(y: origin.y, x: origin.x))
            default:
                break
            }
        }

        // Staff 1 emits first (9 timed elements), staff 2 second (6).
        try #require(rows.count == 15)
        let staff1 = Array(rows.prefix(9))
        let staff2 = Array(rows.suffix(6))

        // Every emitted position in source order must strictly
        // increase in x — within a single voice a later tick must
        // never land left of an earlier one.
        for v in [staff1, staff2] {
            for i in 1..<v.count {
                let msg = "non-monotonic x at index \(i): "
                    + "\(v[i - 1].x) → \(v[i].x)"
                #expect(v[i].x > v[i - 1].x - 0.01,
                    Comment(rawValue: msg))
            }
        }
    }

    @Test("Whole-note voice + quarter voice ⇒ quarters stay uniformly spaced")
    func wholeAgainstQuartersUniform() throws {
        guard #available(macOS 15.0, *) else { return }
        let c4 = Note(pitch: 60, tpc: 14)
        // Voice 0: whole note.  Voice 1: 4 quarter notes.
        // The whole's big duration-width used to dominate tick 0 and
        // push voice-1 quarters to uneven fractions.  Pro-rated gap
        // aggregation spreads the whole across all four gaps, so the
        // quarters end up uniformly spaced.
        let m = Measure(voices: [
            Voice(elements: [
                .clef(Clef(concertClefType: "G")),
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                .chord(Chord(duration: .whole, notes: [c4])),
            ]),
            Voice(elements: [
                .chord(Chord(duration: .quarter, notes: [c4])),
                .chord(Chord(duration: .quarter, notes: [c4])),
                .chord(Chord(duration: .quarter, notes: [c4])),
                .chord(Chord(duration: .quarter, notes: [c4])),
            ]),
        ])
        let staff = StaffContent(id: 1, measures: [m])
        let score = Score(
            division: 480,
            parts: [Part(
                id: "P", trackName: nil,
                instrument: Instrument(
                    id: "x", longName: "T", shortName: "T"))],
            staves: [staff])
        let doc = LayoutEngine.layout(
            score: score,
            options: .init(wrapToViewWidth: false),
            availableWidth: 900)
        let measure = try #require(doc.systems.first?.measures.first)

        // Voice 0 (whole) then voice 1 (4 quarters), in emission order.
        var xs: [CGFloat] = []
        for el in measure.elements {
            if case .chord(_, _, _, let so, _, _, _, _) = el {
                xs.append(so.x)
            }
        }
        try #require(xs.count == 5)
        let whole = xs[0]
        let quarters = Array(xs.dropFirst())

        // Whole sits at tick 0 with quarter #1.
        #expect(abs(whole - quarters[0]) < 0.01)

        // Quarter-to-quarter gaps must all be ~equal.
        let g1 = quarters[1] - quarters[0]
        let g2 = quarters[2] - quarters[1]
        let g3 = quarters[3] - quarters[2]
        #expect(abs(g1 - g2) < 0.5,
            "gap 0-1 = \(g1), gap 1-2 = \(g2)")
        #expect(abs(g2 - g3) < 0.5,
            "gap 1-2 = \(g2), gap 2-3 = \(g3)")
    }

    @Test("tickColumns fraction matches the higher-pressure voice at each tick")
    func tickColumnsMaxFractionRule() throws {
        guard #available(macOS 15.0, *) else { return }

        // Single staff, single voice, four 8ths — a simpler shape
        // that anchors the numeric behaviour of tickColumns.
        let c4 = Note(pitch: 60, tpc: 14)
        let voice = Voice(elements: [
            .chord(Chord(duration: .eighth, notes: [c4])),
            .chord(Chord(duration: .eighth, notes: [c4])),
            .chord(Chord(duration: .eighth, notes: [c4])),
            .chord(Chord(duration: .eighth, notes: [c4])),
        ])
        let staff = StaffContent(id: 1, measures: [
            Measure(voices: [voice])
        ])
        let metrics = StaffMetrics(staffSize: 28)
        let schedule = LayoutEngine.HeaderSchedule(
            clefX: 0, keySigX: 0, timeSigX: 0, contentStartX: 40)
        let cols = LayoutEngine.tickColumns(
            staves: [staff],
            measureIdx: 0,
            metrics: metrics,
            headerSchedule: schedule,
            width: 400,
            division: 480)

        // Each 8th is 240 ticks at division 480, so ticks are
        // 0, 240, 480, 720. All four should be present.
        #expect(cols[0] != nil)
        #expect(cols[240] != nil)
        #expect(cols[480] != nil)
        #expect(cols[720] != nil)

        // Four uniform weights ⇒ fractions 0, 0.25, 0.5, 0.75 —
        // the inter-tick gap must be constant.
        let xs = [0, 240, 480, 720].compactMap { cols[$0] }
        let gap1 = xs[1] - xs[0]
        let gap2 = xs[2] - xs[1]
        let gap3 = xs[3] - xs[2]
        #expect(abs(gap1 - gap2) < 0.01)
        #expect(abs(gap2 - gap3) < 0.01)
    }
}
#endif
