@testable import SheetMusicCore
import Testing

/// Chord markings and annotations on a drum staff (design 2026-10-26, drum voice conversion, §4.5; D1, D3, D5, D6). A
/// chord's marks follow its notes — to every part when it splits, as a union when chords merge — a grace chord rides
/// on the chord at its onset in the voice of its own pitches, and every annotation keeps its tick, the chords of its
/// voice cut there. A marking that cannot travel without changing what plays leaves its bar as written. Every test
/// converts and holds the result to the sound gate, a bar left as written included.
@Suite("RevoiceDrumStaff markings")
struct RevoiceMarkingTests {
    private static let accent = ChordArticulation(kind: .accent)
    private static let staccato = ChordArticulation(kind: .staccato)
    private static let caseOne = "H+K/8 H/8 H+S/8 H/8 H+K/8 H+K/8 H+S/8 H/8"

    /// A stream element that is not a chord or rest, and the tick it stands at.
    private struct Placed: Equatable {
        let tick: Int
        let element: VoiceElement
    }

    private static func preview(_ score: Score, to map: [Int: Int]) -> RevoicePreview {
        RevoiceDrumStaff(staff: RevoiceFixtures.staff, voiceForPitch: map, policy: .default).preview(in: score)
    }

    /// `score` with the chord at `element` of bar `measure`'s voice `voice` changed by `edit`. Element 0 of bar 0's
    /// voice 0 is the time signature.
    private static func marking(
        _ score: Score, measure: Int = 0, voice: Int = 0, element: Int, _ edit: (inout Chord) -> Void,
    ) -> Score {
        RevoiceFixtures.editingChord(score, measure: measure, voice: voice, element: element, edit)
    }

    /// Converts `score` to `map` and holds the result to the sound gate.
    @discardableResult
    private static func convertKeepingSound(
        _ score: Score, to map: [Int: Int], sourceLocation: SourceLocation = #_sourceLocation,
    ) throws -> Score {
        let (after, _) = try RevoiceFixtures.converted(score, to: map)
        try RevoiceSoundGate.expectKeepsSound(
            before: score, after: after, staff: RevoiceFixtures.staff, sourceLocation: sourceLocation,
        )
        return after
    }

    /// Every element of bar 0's voice `voice` that is not a chord or rest, with the tick it stands at in a 4/4 bar.
    private static func annotations(_ score: Score, voice: Int) -> [Placed] {
        guard let voices = score[RevoiceFixtures.staff]?.measures[0].voices, voices.indices.contains(voice) else {
            return []
        }
        let bar = Fraction(numerator: 1, denominator: 1)
        var tick = 0
        var found: [Placed] = []
        for element in voices[voice].elements {
            defer { tick += element.cursorAdvance(division: RevoiceFixtures.division, in: bar) }
            if case .chord = element { continue }
            found.append(Placed(tick: tick, element: element))
        }
        return found
    }

    // MARK: Chord marks (§4.5, D1, D3)

    @Test func `an accent on a split chord goes to both parts`() throws {
        let score = Self.marking(RevoiceFixtures.score([["H+K/4 H/4 H/4 H/4"]]), element: 1) { chord in
            chord.articulations = [Self.accent]
        }
        let after = try Self.convertKeepingSound(score, to: RevoiceFixtures.handsAndFeet)
        #expect(RevoiceFixtures.voices(after, measure: 0) == ["H/4 H/4 H/4 H/4", "K/4 r/4 r/2"])
        #expect(RevoiceFixtures.chords(after, voice: 0).first?.articulations == [Self.accent])
        #expect(RevoiceFixtures.chords(after, voice: 1).first?.articulations == [Self.accent])
    }

    /// A mark that is drawn but plays as written goes to the lowest part only: layout puts the open sign above every
    /// chord it is on, so a copy on the kick would draw an "o" over each kick.
    @Test func `an open sign on a split chord goes to the lowest part only`() throws {
        let muteOpen = ChordArticulation(kind: .muteOpen)
        let score = Self.marking(RevoiceFixtures.score([["H+K/4 H/4 H/4 H/4"]]), element: 1) { chord in
            chord.articulations = [muteOpen]
        }
        let after = try Self.convertKeepingSound(score, to: RevoiceFixtures.handsAndFeet)
        #expect(RevoiceFixtures.voices(after, measure: 0) == ["H/4 H/4 H/4 H/4", "K/4 r/4 r/2"])
        #expect(RevoiceFixtures.chords(after, voice: 0).first?.articulations == [muteOpen])
        #expect(RevoiceFixtures.chords(after, voice: 1).first?.articulations == [])
    }

    /// An accent plays on every note, so it goes to both parts; the closed sign beside it goes to the lowest only.
    @Test func `an accent and a closed sign on a split chord part ways`() throws {
        let muteClosed = ChordArticulation(kind: .muteClosed)
        let score = Self.marking(RevoiceFixtures.score([["H+K/4 H/4 H/4 H/4"]]), element: 1) { chord in
            chord.articulations = [Self.accent, muteClosed]
        }
        let after = try Self.convertKeepingSound(score, to: RevoiceFixtures.handsAndFeet)
        #expect(RevoiceFixtures.chords(after, voice: 0).first?.articulations == [Self.accent, muteClosed])
        #expect(RevoiceFixtures.chords(after, voice: 1).first?.articulations == [Self.accent])
    }

    /// A merge unites its sources' marks (D1), and the part that splits back out is the lowest again: the open sign
    /// ends on the hi-hat and the kick gains none.
    @Test func `an open sign survives a merge and a split on the hi-hat only`() throws {
        let muteOpen = ChordArticulation(kind: .muteOpen)
        let score = Self.marking(
            RevoiceFixtures.score([["H/4 H/4 H/4 H/4", "K/4 r/4 r/2"]]), element: 1,
        ) { $0.articulations = [muteOpen] }
        let merged = try Self.convertKeepingSound(score, to: RevoiceFixtures.oneVoice)
        #expect(RevoiceFixtures.chords(merged, voice: 0).first?.articulations == [muteOpen])
        let after = try Self.convertKeepingSound(merged, to: RevoiceFixtures.handsAndFeet)
        #expect(RevoiceFixtures.voices(after, measure: 0) == ["H/4 H/4 H/4 H/4", "K/4 r/4 r/2"])
        #expect(RevoiceFixtures.chords(after, voice: 0).first?.articulations == [muteOpen])
        #expect(RevoiceFixtures.chords(after, voice: 1).first?.articulations == [])
    }

    /// The choke stops only the chord's cymbals, so it goes to the part that holds the crash: on the kick it would
    /// draw a mark that stops nothing.
    @Test func `a choke on a split crash and kick goes to the crash's part only`() throws {
        let choke = ChordArticulation(kind: .chokeCymbal)
        let score = Self.marking(RevoiceFixtures.score([["C+K/4 C/4 C/4 C/4"]]), element: 1) { chord in
            chord.articulations = [Self.accent, choke]
        }
        let after = try Self.convertKeepingSound(score, to: RevoiceFixtures.handsAndFeet)
        #expect(RevoiceFixtures.voices(after, measure: 0) == ["C/4 C/4 C/4 C/4", "K/4 r/4 r/2"])
        #expect(RevoiceFixtures.chords(after, voice: 0).first?.articulations == [Self.accent, choke])
        #expect(RevoiceFixtures.chords(after, voice: 1).first?.articulations == [Self.accent])
    }

    /// A choke on a chord with no cymbal at all stops nothing anywhere, so it travels as any playing mark does.
    @Test func `a choke on a split snare and kick goes to both parts`() throws {
        let choke = ChordArticulation(kind: .chokeCymbal)
        let score = Self.marking(RevoiceFixtures.score([["S+K/4 S/4 S/4 S/4"]]), element: 1) { chord in
            chord.articulations = [choke]
        }
        let after = try Self.convertKeepingSound(score, to: RevoiceFixtures.handsAndFeet)
        #expect(RevoiceFixtures.voices(after, measure: 0) == ["S/4 S/4 S/4 S/4", "K/4 r/4 r/2"])
        #expect(RevoiceFixtures.chords(after, voice: 0).first?.articulations == [choke])
        #expect(RevoiceFixtures.chords(after, voice: 1).first?.articulations == [choke])
    }

    @Test func `a choke survives a split and a merge on the crash, once`() throws {
        let choke = ChordArticulation(kind: .chokeCymbal)
        let score = Self.marking(RevoiceFixtures.score([["C+K/4 C/4 C/4 C/4"]]), element: 1) { chord in
            chord.articulations = [choke]
        }
        let split = try Self.convertKeepingSound(score, to: RevoiceFixtures.handsAndFeet)
        let merged = try Self.convertKeepingSound(split, to: RevoiceFixtures.oneVoice)
        #expect(RevoiceFixtures.voices(merged, measure: 0) == ["C+K/4 C/4 C/4 C/4"])
        #expect(RevoiceFixtures.chords(merged, voice: 0).first?.articulations == [choke])
        let markedLater = RevoiceFixtures.chords(merged, voice: 0).dropFirst().filter { !$0.articulations.isEmpty }
        #expect(markedLater.isEmpty)
    }

    /// D1: the kick merged with an accented snare takes the accent. In bar 1 both carry one, and the kick adds a
    /// staccato: the union lists each kind once, the snare's first.
    @Test func `merged chords take the union of their marks`() throws {
        var score = RevoiceFixtures.score([
            ["S/4 H/4 H/4 H/4", "K/4 r/4 r/2"], ["S/4 H/4 H/4 H/4", "K/4 r/4 r/2"],
        ])
        score = Self.marking(score, element: 1) { $0.articulations = [Self.accent] }
        score = Self.marking(score, measure: 1, element: 0) { $0.articulations = [Self.accent] }
        score = Self.marking(score, measure: 1, voice: 1, element: 0) { chord in
            chord.articulations = [Self.staccato, Self.accent]
        }
        let after = try Self.convertKeepingSound(score, to: RevoiceFixtures.oneVoice)
        #expect(RevoiceFixtures.voices(after, measure: 0) == ["S+K/4 H/4 H/4 H/4"])
        let merged = RevoiceFixtures.chords(after, voice: 0).first
        #expect(merged?.notes.map(\.pitch) == [36, 38])
        #expect(merged?.articulations == [Self.accent])
        let union = RevoiceFixtures.chords(after, measure: 1, voice: 0).first?.articulations
        #expect(union == [Self.accent, Self.staccato])
    }

    @Test func `a converted chord drops its forced stem`() throws {
        let score = Self.marking(RevoiceFixtures.score([["H+K/4 H/4 H/4 H/4"]]), element: 1) { chord in
            chord.stemDirection = .up
            chord.beamStemDirection = .up
        }
        let after = try Self.convertKeepingSound(score, to: RevoiceFixtures.handsAndFeet)
        #expect(RevoiceFixtures.voices(after, measure: 0) == ["H/4 H/4 H/4 H/4", "K/4 r/4 r/2"])
        let parts = [RevoiceFixtures.chords(after, voice: 0).first, RevoiceFixtures.chords(after, voice: 1).first]
        #expect(parts.map { $0?.stemDirection } == [nil, nil])
        #expect(parts.map { $0?.beamStemDirection } == [nil, nil])
    }

    /// A chord-level line and the lyric stay with the part in the lowest voice; a line written on one note goes with
    /// that note, its index naming the note in the part it lands in.
    @Test func `chord lines and lyrics stay with the lowest part`() throws {
        let fall = ChordLine(kind: .fall)
        let lyric = Lyric(text: "la")
        let score = Self.marking(RevoiceFixtures.score([["C+K/4 H/4 H/4 H/4"]]), element: 1) { chord in
            // Notes ascend: index 0 is the kick, 1 the crash.
            chord.chordLines = [fall, ChordLine(kind: .scoop, noteIndex: 0), ChordLine(kind: .doit, noteIndex: 1)]
            chord.lyrics = [lyric]
        }
        let after = try Self.convertKeepingSound(score, to: RevoiceFixtures.handsAndFeet)
        #expect(RevoiceFixtures.voices(after, measure: 0) == ["C/4 H/4 H/4 H/4", "K/4 r/4 r/2"])
        let crash = RevoiceFixtures.chords(after, voice: 0).first
        let kick = RevoiceFixtures.chords(after, voice: 1).first
        #expect(crash?.chordLines == [fall, ChordLine(kind: .doit, noteIndex: 0)])
        #expect(kick?.chordLines == [ChordLine(kind: .scoop, noteIndex: 0)])
        #expect(crash?.lyrics == [lyric])
        #expect(kick?.lyrics == [])
    }

    @Test func `an arpeggio on a split chord leaves the bar`() throws {
        let score = Self.marking(
            RevoiceFixtures.score([["H+K/4 H/4 H/4 H/4"], ["H+K/4 H/4 H/4 H/4"]]), element: 1,
        ) { $0.arpeggio = Arpeggio(subtype: 0) }
        #expect(Self.preview(score, to: RevoiceFixtures.handsAndFeet)
            == RevoicePreview(rewrittenMeasures: [1], measuresLeftAsWritten: [0]))
        #expect(RevoiceFixtures.barPlan(score, measure: 0, to: RevoiceFixtures.handsAndFeet)
            == .leftAsWritten(.markings))
        let after = try Self.convertKeepingSound(score, to: RevoiceFixtures.handsAndFeet)
        #expect(after.parts[0].staves[0].measures[0].voices == score.parts[0].staves[0].measures[0].voices)
    }

    /// An arpeggio spreads its notes across its chord's length, so the chord carried whole keeps its eighth. Free, it
    /// would reach beat 2 as a quarter.
    @Test func `an arpeggiated chord keeps its length`() throws {
        let score = Self.marking(RevoiceFixtures.score([["C+H/8 r/8 H+K/4 H/2"]]), element: 1) { chord in
            chord.arpeggio = Arpeggio(subtype: 0)
        }
        let after = try Self.convertKeepingSound(score, to: RevoiceFixtures.handsAndFeet)
        #expect(RevoiceFixtures.voices(after, measure: 0) == ["C+H/8 r/8 H/4 H/2", "r/4 K/4 r/2"])
        #expect(RevoiceFixtures.chords(after, voice: 0).first?.arpeggio == Arpeggio(subtype: 0))
    }

    /// The same regression A3 covers (`a kick merged onto a rolled snare leaves the bar as written`), kept here as the
    /// table's tremolo row.
    @Test func `a plain kick onto a rolled snare leaves the bar`() throws {
        let score = Self.marking(RevoiceFixtures.score([["S/4 H/4 H/4 H/4", "K/4 r/4 r/2"]]), element: 1) { chord in
            chord.tremolo = Tremolo(subtype: .r16)
        }
        #expect(Self.preview(score, to: RevoiceFixtures.oneVoice)
            == RevoicePreview(rewrittenMeasures: [], measuresLeftAsWritten: [0]))
        #expect(RevoiceFixtures.barPlan(score, measure: 0, to: RevoiceFixtures.oneVoice) == .leftAsWritten(.markings))
        try Self.convertKeepingSound(score, to: RevoiceFixtures.oneVoice)
    }

    /// In one voice each kick merges with the snare on 1: bar 0's snare has a trill the kick lacks, bar 1's two
    /// chords both carry a lyric, and bar 2's kick carries a slur that would change voice.
    @Test func `marks two chords cannot share leave their bars`() throws {
        let slur = Spanner(kind: .slur, rawType: "Slur", nextFractionsOffset: Fraction(numerator: 1, denominator: 4))
        var score = RevoiceFixtures.score(Array(repeating: ["S/4 H/4 H/4 H/4", "K/4 r/4 r/2"], count: 3))
        score = Self.marking(score, element: 1) { $0.ornaments = [ChordOrnament(kind: .trill)] }
        score = Self.marking(score, measure: 1, element: 0) { $0.lyrics = [Lyric(text: "la")] }
        score = Self.marking(score, measure: 1, voice: 1, element: 0) { $0.lyrics = [Lyric(text: "da")] }
        score = Self.marking(score, measure: 2, voice: 1, element: 0) { $0.spanners = [slur] }
        #expect(Self.preview(score, to: RevoiceFixtures.oneVoice)
            == RevoicePreview(rewrittenMeasures: [], measuresLeftAsWritten: [0, 1, 2]))
        for measure in 0 ..< 3 {
            #expect(RevoiceFixtures.barPlan(score, measure: measure, to: RevoiceFixtures.oneVoice)
                == .leftAsWritten(.markings))
        }
        try Self.convertKeepingSound(score, to: RevoiceFixtures.oneVoice)
    }

    // MARK: Grace chords (§4.5)

    @Test func `a flam stays with the snare`() throws {
        let flam = RevoiceFixtures.grace(.acciaccatura, "S")
        let score = Self.marking(RevoiceFixtures.score([["S+K/4 H/4 H/4 H/4"]]), element: 1) { chord in
            chord.graceNotesBefore = [flam]
        }
        let after = try Self.convertKeepingSound(score, to: RevoiceFixtures.handsAndFeet)
        #expect(RevoiceFixtures.voices(after, measure: 0) == ["S/4 H/4 H/4 H/4", "K/4 r/4 r/2"])
        #expect(RevoiceFixtures.chords(after, voice: 0).first?.graceNotesBefore.values == [flam])
        #expect(RevoiceFixtures.chords(after, voice: 1).first?.graceNotesBefore.isEmpty == true)
    }

    /// The grace kick belongs in voice 2, which holds no chord on 1. Bar 1 still converts.
    @Test func `a grace with no chord to land on leaves the bar`() throws {
        let score = Self.marking(
            RevoiceFixtures.score([["H/4 H/4 H/4 H/4"], ["H+K/4 H/4 H/4 H/4"]]), element: 1,
        ) { $0.graceNotesBefore = [RevoiceFixtures.grace(.acciaccatura, "K")] }
        #expect(Self.preview(score, to: RevoiceFixtures.handsAndFeet)
            == RevoicePreview(rewrittenMeasures: [1], measuresLeftAsWritten: [0]))
        #expect(RevoiceFixtures.barPlan(score, measure: 0, to: RevoiceFixtures.handsAndFeet)
            == .leftAsWritten(.markings))
        try Self.convertKeepingSound(score, to: RevoiceFixtures.handsAndFeet)
    }

    /// The kick's and the snare's flams sound one after the other, each timed from the first; ridden on two chords,
    /// each would be timed alone.
    @Test func `one chord's graces split across two chords leave the bar`() throws {
        let score = Self.marking(RevoiceFixtures.score([["S+K/4 H/4 H/4 H/4"]]), element: 1) { chord in
            chord.graceNotesBefore = [
                RevoiceFixtures.grace(.acciaccatura, "K"), RevoiceFixtures.grace(.acciaccatura, "S"),
            ]
        }
        #expect(RevoiceFixtures.barPlan(score, measure: 0, to: RevoiceFixtures.handsAndFeet)
            == .leftAsWritten(.markings))
        try Self.convertKeepingSound(score, to: RevoiceFixtures.handsAndFeet)
    }

    /// In one voice the snare's flam and the kick's would ride on the same side of one chord, timed one after the
    /// other rather than each from the chord.
    @Test func `graces of two merging chords leave the bar`() throws {
        var score = RevoiceFixtures.score([["S/4 H/4 H/4 H/4", "K/4 r/4 r/2"]])
        score = Self.marking(score, element: 1) { $0.graceNotesBefore = [RevoiceFixtures.grace(.acciaccatura, "S")] }
        score = Self.marking(score, voice: 1, element: 0) { chord in
            chord.graceNotesBefore = [RevoiceFixtures.grace(.acciaccatura, "K")]
        }
        #expect(RevoiceFixtures.barPlan(score, measure: 0, to: RevoiceFixtures.oneVoice) == .leftAsWritten(.markings))
        try Self.convertKeepingSound(score, to: RevoiceFixtures.oneVoice)
    }

    /// An appoggiatura takes its time from the head of its chord, delaying every note of it; riding with the snare
    /// alone, it would leave the kick sounding earlier than it did.
    @Test func `a grace that delays its chord leaves the bar when the chord splits`() throws {
        let score = Self.marking(RevoiceFixtures.score([["S+K/4 H/4 H/4 H/4"]]), element: 1) { chord in
            chord.graceNotesBefore = [RevoiceFixtures.grace(.appoggiatura, "S")]
        }
        #expect(RevoiceFixtures.barPlan(score, measure: 0, to: RevoiceFixtures.handsAndFeet)
            == .leftAsWritten(.markings))
        try Self.convertKeepingSound(score, to: RevoiceFixtures.handsAndFeet)
    }

    /// After-graces sound in their chord's tail. Free, the hi-hat on 1 would become a quarter and the grace would sound
    /// an eighth later; it keeps its eighth.
    @Test func `after-graces keep their chord's length`() throws {
        let grace = RevoiceFixtures.grace(.grace8after, "S")
        let score = Self.marking(RevoiceFixtures.score([["H+K/8 r/8 H/4 H/2"]]), element: 1) { chord in
            chord.graceNotesAfter = [grace]
        }
        let after = try Self.convertKeepingSound(score, to: RevoiceFixtures.handsAndFeet)
        #expect(RevoiceFixtures.voices(after, measure: 0) == ["H/8 r/8 H/4 H/2", "K/4 r/4 r/2"])
        #expect(RevoiceFixtures.chords(after, voice: 0).first?.graceNotesAfter.values == [grace])
        #expect(RevoiceFixtures.chords(after, voice: 1).first?.graceNotesAfter.isEmpty == true)
    }

    /// The kick's after-grace snare goes to voice 1 and rides on the hi-hat on 1, which takes the kick's eighth so the
    /// grace sounds where it did. Free, the hi-hat would keep its quarter and the grace would sound an eighth later.
    @Test func `an after-grace handed to another chord keeps its timing`() throws {
        let grace = RevoiceFixtures.grace(.grace8after, "S")
        let score = Self.marking(
            RevoiceFixtures.score([["H/4 H/4 H/4 H/4", "K/8 r/8 r/4 r/2"]]), voice: 1, element: 0,
        ) { $0.graceNotesAfter = [grace] }
        let after = try Self.convertKeepingSound(score, to: RevoiceFixtures.handsAndFeet)
        #expect(RevoiceFixtures.voices(after, measure: 0) == ["H/8 r/8 H/4 H/4 H/4", "K/4 r/4 r/2"])
        #expect(RevoiceFixtures.chords(after, voice: 0).first?.graceNotesAfter.values == [grace])
        #expect(RevoiceFixtures.chords(after, voice: 1).first?.graceNotesAfter.isEmpty == true)
    }

    /// The hi-hat on 1 is tied to the one on 2, so it lasts its quarter; the kick's after-grace would need it to end
    /// after an eighth.
    @Test func `an after-grace host that must last longer leaves the bar`() throws {
        let score = Self.marking(
            RevoiceFixtures.score([["H/4~ ~H/4 H/4 H/4", "K/8 r/8 r/4 r/2"]]), voice: 1, element: 0,
        ) { $0.graceNotesAfter = [RevoiceFixtures.grace(.grace8after, "S")] }
        #expect(RevoiceFixtures.barPlan(score, measure: 0, to: RevoiceFixtures.handsAndFeet)
            == .leftAsWritten(.markings))
        try Self.convertKeepingSound(score, to: RevoiceFixtures.handsAndFeet)
    }

    /// The kick's after-grace would ride on the hi-hat on 1. In bar 0 that hi-hat rolls, and a rolled chord plays no
    /// grace; in bar 1 it spreads an arpeggio, which the grace's share of its tail would respace. Bar 2 converts.
    @Test func `a grace handed to a rolled or arpeggiated chord leaves the bar`() throws {
        let kick = ["K/8 r/8 r/4 r/2"]
        var score = RevoiceFixtures.score([
            ["H/8 r/8 H/4 H/2"] + kick, ["C+H/8 r/8 H/4 H/2"] + kick, ["H+K/4 H/4 H/4 H/4"],
        ])
        score = Self.marking(score, element: 1) { $0.tremolo = Tremolo(subtype: .r16) }
        score = Self.marking(score, measure: 1, element: 0) { $0.arpeggio = Arpeggio(subtype: 0) }
        for measure in 0 ..< 2 {
            score = Self.marking(score, measure: measure, voice: 1, element: 0) { chord in
                chord.graceNotesAfter = [RevoiceFixtures.grace(.grace8after, "S")]
            }
        }
        #expect(Self.preview(score, to: RevoiceFixtures.handsAndFeet)
            == RevoicePreview(rewrittenMeasures: [2], measuresLeftAsWritten: [0, 1]))
        for measure in 0 ..< 2 {
            #expect(RevoiceFixtures.barPlan(score, measure: measure, to: RevoiceFixtures.handsAndFeet)
                == .leftAsWritten(.markings))
        }
        try Self.convertKeepingSound(score, to: RevoiceFixtures.handsAndFeet)
    }

    // MARK: Annotations (§4.5, D5, D6)

    /// Review Focus 1: the sticking on the "and" of 1 stays in voice 1 while its kick goes to voice 2, so the hi-hat on
    /// 1 is cut there rather than reaching beat 2.
    @Test func `a sticking keeps its tick when its kick moves away`() throws {
        let sticking = Sticking(text: "R")
        let score = RevoiceFixtures.inserting(
            .sticking(sticking), into: RevoiceFixtures.score([["H+K/8 K/8 H/4 H/2"]]), at: 2,
        )
        let after = try Self.convertKeepingSound(score, to: RevoiceFixtures.handsAndFeet)
        #expect(RevoiceFixtures.voices(after, measure: 0) == ["H/8 r/8 H/4 H/2", "K/8 K/8 r/4 r/2"])
        #expect(Self.annotations(after, voice: 0).last == Placed(tick: 240, element: .sticking(sticking)))
        #expect(Self.annotations(after, voice: 1).isEmpty)
    }

    /// Review Focus 5: a MusicXML chart's rest-only voice 2 carries a dynamic. The voice goes, the dynamic moves to
    /// voice 1 at its tick, and voice 1 keeps every chord as it was.
    @Test func `a dynamic in a rest-only voice 2 moves to voice 1 at its tick`() throws {
        let dynamic = Dynamic(subtype: "p", velocity: 49)
        let score = RevoiceFixtures.inserting(
            .dynamic(dynamic), into: RevoiceFixtures.score([["H/4 H/4 H/4 H/4", "r/4 r/4 r/2"]]), voice: 1, at: 1,
        )
        let after = try Self.convertKeepingSound(score, to: RevoiceFixtures.oneVoice)
        #expect(after.parts[0].staves[0].measures[0].voices.count == 1)
        #expect(Self.annotations(after, voice: 0).last == Placed(tick: 480, element: .dynamic(dynamic)))
        #expect(RevoiceFixtures.chords(after, voice: 0) == RevoiceFixtures.chords(score, voice: 0))
    }

    /// D6: from the bar of the first dynamic or hairpin that plays in its own voice only, no bar moves a note between
    /// voices. Bar 1 holds the dynamic in one score and the hairpin in the other.
    @Test func `a voice-only dynamic or hairpin holds the rest of the staff`() throws {
        let hairpin = Spanner(
            kind: .hairpin, rawType: "HairPin", nextMeasuresOffset: 1,
            hairpin: Spanner.HairpinPayload(subtype: .crescendo, voiceAssignment: .currentVoiceOnly),
        )
        let markings: [VoiceElement] = [
            .dynamic(Dynamic(subtype: "p", velocity: 49, voiceAssignment: .currentVoiceOnly)), .spanner(hairpin),
        ]
        for marking in markings {
            let score = RevoiceFixtures.inserting(
                marking, into: RevoiceFixtures.score(Array(repeating: [Self.caseOne], count: 3)), measure: 1, at: 0,
            )
            #expect(Self.preview(score, to: RevoiceFixtures.handsAndFeet)
                == RevoicePreview(rewrittenMeasures: [0], measuresLeftAsWritten: [1, 2]))
            let after = try Self.convertKeepingSound(score, to: RevoiceFixtures.handsAndFeet)
            #expect(after.parts[0].staves[0].measures.map(\.voices.count) == [2, 1, 1])
        }
    }

    /// The sticking on the "and" of 1 in voice 2 lands in voice 1, inside the snare's roll on 1, which keeps its
    /// quarter: no chord can start there.
    @Test func `an annotation inside a roll leaves the bar`() throws {
        var score = RevoiceFixtures.score([["S/4 H/4 H/4 H/4", "r/8 r/8 K/4 r/2"]])
        score = Self.marking(score, element: 1) { $0.tremolo = Tremolo(subtype: .r16) }
        score = RevoiceFixtures.inserting(.sticking(Sticking(text: "R")), into: score, voice: 1, at: 1)
        #expect(RevoiceFixtures.barPlan(score, measure: 0, to: RevoiceFixtures.oneVoice)
            == .leftAsWritten(.annotationPlacement))
        try Self.convertKeepingSound(score, to: RevoiceFixtures.oneVoice)
    }

    /// A fermata holds the chord after it for as long as that chord lasts. Free, the crash would reach beat 2 and the
    /// hold would double; it keeps its eighth.
    @Test func `a fermata keeps the length of the chord it holds`() throws {
        let fermata = Fermata(subtype: "fermataAbove", timeStretch: 2)
        let score = RevoiceFixtures.inserting(
            .fermata(fermata), into: RevoiceFixtures.score([["C+K/8 r/8 r/4 r/2"]]), at: 1,
        )
        let after = try Self.convertKeepingSound(score, to: RevoiceFixtures.handsAndFeet)
        #expect(RevoiceFixtures.voices(after, measure: 0) == ["C/8 r/8 r/4 r/2", "K/4 r/4 r/2"])
        #expect(Self.annotations(after, voice: 0).last == Placed(tick: 0, element: .fermata(fermata)))
    }

    /// A caesura's pause delays every later note of its voice, so a bar whose notes would change voice around one is
    /// left as written.
    @Test func `a caesura inside a bar leaves it as written`() throws {
        let caesura = Breath(kind: .caesura(.normal), pause: 0.5)
        let score = RevoiceFixtures.inserting(
            .breath(caesura), into: RevoiceFixtures.score([["H+K/4 H/4 H/4 H/4"]]), at: 3,
        )
        #expect(RevoiceFixtures.barPlan(score, measure: 0, to: RevoiceFixtures.handsAndFeet)
            == .leftAsWritten(.unsupported))
        try Self.convertKeepingSound(score, to: RevoiceFixtures.handsAndFeet)
    }
}
