import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
import Testing

/// What the corpus gate looked at, so a green run can be told from an empty one.
struct RevoiceSoundGateCounts {
    var scores = 0
    var skipped = 0
    var staves = 0
    var conversions = 0
    /// Bars the conversion to hands and feet rewrote / left as written.
    var rewrittenToHandsAndFeet = 0
    var leftToHandsAndFeet = 0
    /// The same for the conversion to one voice.
    var rewrittenToOneVoice = 0
    var leftToOneVoice = 0
    /// The first bars left as written, as `<score> bar <n> (<direction>)`.
    var firstLeft: [String] = []
}

/// The sound gate (design 2026-10-26, drum voice conversion, §5) run over the fixture corpus: every percussion staff
/// converts to hands and feet and back to one voice without changing what plays or where a marking sits, and one voice
/// is a fixed point. The synthetic cases beside it are the ones the corpus may not hold.
@Suite("RevoiceDrumStaff sound gate")
struct RevoiceSoundGateTests {
    /// The pad's hands-and-feet split read from the GM kit: every drum the kit engraves in voice 2 (index 1).
    private static let kitHandsAndFeet: [Int: Int] = GMDrumset.entries.compactMapValues { entry in
        entry.voiceIndex == 0 ? nil : entry.voiceIndex
    }

    /// Plans and applies `RevoiceDrumStaff` over `staff` in place, with the allocator the whole chain shares. Nil when
    /// the command would change nothing.
    private static func convert(
        _ score: inout Score, ids: inout EIDAllocator, staff: StaffAddress, to map: [Int: Int],
    ) throws -> CompositeEditCommand? {
        let command = RevoiceDrumStaff(staff: staff, voiceForPitch: map, policy: .default)
        guard let plan = try command.plan(in: score, ids: ids) else { return nil }
        _ = try plan.apply(to: &score, ids: &ids)
        return plan
    }

    private static func preview(_ score: Score, staff: StaffAddress, to map: [Int: Int]) -> RevoicePreview {
        RevoiceDrumStaff(staff: staff, voiceForPitch: map, policy: .default).preview(in: score)
    }

    /// Converts `address` of `parsed` to hands and feet, then to one voice, each step judged by the sound gate against
    /// the step before it, then expects a second conversion to the same target to plan nothing. `name` labels problems.
    private static func gate(
        _ parsed: Score, address: StaffAddress, name: String, counts: inout RevoiceSoundGateCounts,
    ) throws {
        counts.staves += 1
        var score = parsed
        var ids = EIDAllocator()
        score.assignMissingIDs(using: &ids)
        for (isHandsAndFeet, map) in [(true, Self.kitHandsAndFeet), (false, RevoiceFixtures.oneVoice)] {
            let before = score
            let preview = Self.preview(before, staff: address, to: map)
            if isHandsAndFeet {
                counts.rewrittenToHandsAndFeet += preview.rewrittenMeasures.count
                counts.leftToHandsAndFeet += preview.measuresLeftAsWritten.count
            } else {
                counts.rewrittenToOneVoice += preview.rewrittenMeasures.count
                counts.leftToOneVoice += preview.measuresLeftAsWritten.count
            }
            for bar in preview.measuresLeftAsWritten where counts.firstLeft.count < 20 {
                counts.firstLeft.append("\(name) bar \(bar) (\(isHandsAndFeet ? "hands and feet" : "one voice"))")
            }
            counts.conversions += 1
            _ = try Self.convert(&score, ids: &ids, staff: address, to: map)
            let problems = try RevoiceSoundGate.problems(before: before, after: score, staff: address)
            #expect(problems.isEmpty, "\(name) to \(isHandsAndFeet ? "hands and feet" : "one voice"): \(problems)")
            let again = try Self.convert(&score, ids: &ids, staff: address, to: map)
            #expect(again == nil, "converting again plans nothing: \(name)")
        }
    }

    private static func drumStaves(of score: Score) -> [StaffAddress] {
        score.allStaves.map(\.address).filter { score.parts[$0.partIndex].instrument.useDrumset }
    }

    @Test func `every percussion staff in the fixtures converts both ways without changing its sound`() throws {
        var counts = RevoiceSoundGateCounts()
        for url in FormatRhythmsInvariantTests.topLevelFixtures() {
            guard let parsed = try? MSCXParser.parse(contentsOf: url), (try? MidiRenderer.render(score: parsed)) != nil
            else {
                counts.skipped += 1
                continue
            }
            counts.scores += 1
            for address in Self.drumStaves(of: parsed) {
                let name = "\(url.lastPathComponent) staff \(address)"
                try Self.gate(parsed, address: address, name: name, counts: &counts)
            }
        }
        Issue.record(Comment(rawValue: "gate coverage: \(counts)"), severity: .warning)
        // The fixture corpus holds no real drum writing: its only percussion staves are the 149 empty kits of
        // testMidiPort.mscx (a MIDI-port test), so no bar is rewritten or left here. This gate guards parsing, the
        // render and the no-op path; the generated corpus below is what exercises the conversion.
        #expect(counts.scores >= 110, "fixtures parsed and rendered: \(counts.scores)")
        #expect(counts.skipped == 0, "fixtures skipped: \(counts.skipped)")
        #expect(counts.staves >= 149, "percussion staves gated: \(counts.staves)")
    }

    /// The owner's own charts: `SM_REVOICE_SCORE=<path to .mscx or .mscz>` gates every drum staff of that score both
    /// ways and reports the counts and the first bars left as written.
    @Test(
        "owner score: every drum staff converts both ways without changing its sound",
        .enabled(if: ProcessInfo.processInfo.environment["SM_REVOICE_SCORE"] != nil),
    )
    func ownerScore() throws {
        let path = try #require(ProcessInfo.processInfo.environment["SM_REVOICE_SCORE"])
        let url = URL(fileURLWithPath: path)
        let score = url.pathExtension.lowercased() == "mscz"
            ? try MSCZReader.parse(contentsOf: url)
            : try MSCXParser.parse(contentsOf: url)
        var counts = RevoiceSoundGateCounts()
        counts.scores = 1
        for address in Self.drumStaves(of: score) {
            let name = "\(url.lastPathComponent) staff \(address)"
            try Self.gate(score, address: address, name: name, counts: &counts)
        }
        Issue.record(Comment(rawValue: "owner score coverage: \(counts)"), severity: .warning)
        #expect(counts.staves > 0, "the score has no percussion staff")
    }

    // MARK: Generated corpus

    @Test func `generated drum bars convert both ways without changing their sound`() throws {
        var counts = RevoiceSoundGateCounts()
        var rng = SplitMix64(state: 0x5EED_D12A)
        for index in 0 ..< 48 {
            let score = GeneratedDrumScore.make(&rng)
            counts.scores += 1
            try Self.gate(score, address: RevoiceFixtures.staff, name: "generated #\(index)", counts: &counts)
        }
        Issue.record(Comment(rawValue: "generated coverage: \(counts)"), severity: .warning)
        // Floors a little under what the gate saw when they were set (2026-10-27: 48 scores, 96 conversions;
        // to hands and feet 158 bars rewritten and 1 left, to one voice 321 rewritten and 36 left). They turn red
        // if the generator or the command stops reaching either outcome, and are lowered only with a reason.
        #expect(counts.rewrittenToHandsAndFeet >= 150, "rewritten to hands and feet: \(counts.rewrittenToHandsAndFeet)")
        #expect(counts.leftToHandsAndFeet >= 1, "left to hands and feet: \(counts.leftToHandsAndFeet)")
        #expect(counts.rewrittenToOneVoice >= 300, "rewritten to one voice: \(counts.rewrittenToOneVoice)")
        #expect(counts.leftToOneVoice >= 30, "left to one voice: \(counts.leftToOneVoice)")
    }

    // MARK: Synthetic cases

    /// A kick tied from bar 0 into bar 1, where bar 1 holds a rolled snare beside the kick's partner and so is left as
    /// written (a kick merged onto a rolled snare, §4.5). Bar 0's kick moves from voice 2 into voice 1; its partner
    /// stays in bar 1's voice 2. The two pair by position (`CrossVoiceTies`), so it still sounds as one note.
    @Test func `a tie into a bar left as written still sounds as one note`() throws {
        var score = RevoiceFixtures.score([
            ["S/4 S/4 S/4 r/4", "r/2. K/4~"],
            ["S/4 H/4 H/4 H/4", "~K/4 r/4 r/2"],
        ])
        score = RevoiceFixtures.editingChord(score, measure: 1, voice: 0, element: 0) { chord in
            chord.tremolo = Tremolo(subtype: .r16, span: .single)
        }
        let staff = RevoiceFixtures.staff
        #expect(Self.preview(score, staff: staff, to: RevoiceFixtures.oneVoice)
            == RevoicePreview(rewrittenMeasures: [0], measuresLeftAsWritten: [1]))
        let (after, _) = try RevoiceFixtures.converted(score, to: RevoiceFixtures.oneVoice)
        #expect(RevoiceFixtures.voices(after, measure: 0).count == 1)
        #expect(RevoiceFixtures.voices(after, measure: 1).count == 2)
        #expect(FormatRhythmsGate.danglingTies(in: after) == FormatRhythmsGate.danglingTies(in: score))
        try RevoiceSoundGate.expectKeepsSound(before: score, after: after, staff: staff)
    }

    /// The same tie the other way: the kick starts in voice 0 of bar 0 and moves to voice 1 under hands and feet, while
    /// its partner at the head of bar 1 stays in voice 0 because the glissando on the tom after it leaves that bar.
    @Test func `a tie into a bar left as written still sounds as one note when a kick moves to voice two`() throws {
        var score = RevoiceFixtures.score([
            ["S/4 S/4 S/4 K/4~"],
            ["~K/4 T/4 T/4 H/4"],
        ])
        score = RevoiceFixtures.editingChord(score, measure: 1, voice: 0, element: 1) { chord in
            chord.notes.updateNote(at: 0) { $0.glissando = Glissando() }
        }
        let staff = RevoiceFixtures.staff
        #expect(Self.preview(score, staff: staff, to: RevoiceFixtures.handsAndFeet)
            == RevoicePreview(rewrittenMeasures: [0], measuresLeftAsWritten: [1]))
        let (after, _) = try RevoiceFixtures.converted(score, to: RevoiceFixtures.handsAndFeet)
        #expect(RevoiceFixtures.voices(after, measure: 0).count == 2)
        #expect(FormatRhythmsGate.danglingTies(in: after) == FormatRhythmsGate.danglingTies(in: score))
        try RevoiceSoundGate.expectKeepsSound(before: score, after: after, staff: staff)
    }

    /// A bar whose voice 0 is a single measure rest and whose kicks sit in voice 1 converts to one voice: the rest
    /// gives way to the kicks rather than leaving the bar as written.
    @Test func `a measure rest in the first voice gives way to the kicks of the second`() throws {
        let score = RevoiceFixtures.score([["r/m", "K/4 r/4 K/4 r/4"], ["H/4 H/4 H/4 H/4", "K/4 r/4 r/2"]])
        let staff = RevoiceFixtures.staff
        #expect(Self.preview(score, staff: staff, to: RevoiceFixtures.oneVoice)
            == RevoicePreview(rewrittenMeasures: [0, 1], measuresLeftAsWritten: []))
        let (after, _) = try RevoiceFixtures.converted(score, to: RevoiceFixtures.oneVoice)
        #expect(RevoiceFixtures.voices(after, measure: 0).count == 1)
        #expect(RevoiceFixtures.voices(after, measure: 1).count == 1)
        try RevoiceSoundGate.expectKeepsSound(before: score, after: after, staff: staff)
    }

    // An underfull first voice next to normal bars is `RevoiceBarLengthTests`' `an underfull first voice leaves its
    // bar`, which already runs the sound gate over it; no second case here.
}

/// A small seeded generator, so the generated corpus is the same on every run and every machine.
private struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }

    mutating func below(_ bound: Int) -> Int {
        Int(next() % UInt64(bound))
    }

    mutating func chance(oneIn odds: Int) -> Bool {
        below(odds) == 0
    }
}

/// Eight-bar drum scores in 4/4 or 6/8, written in `RevoiceFixtures`' text form so each voice sums to its bar by
/// construction: one or two source voices, hits of K S H P C T on a sixteenth or eighth grid with rests between, and
/// now and then a triplet, a tie into the next bar, a roll, an accent or a dynamic or sticking.
private enum GeneratedDrumScore {
    private static let lengths: [(units: Int, name: String)] = [(1, "16"), (2, "8"), (4, "4")]
    private static let bars = 8

    static func make(_ rng: inout SplitMix64) -> Score {
        let compound = rng.chance(oneIn: 3)
        let units = compound ? 12 : 16
        let meter = TimeSignature(numerator: compound ? 6 : 4, denominator: compound ? 8 : 4)
        var written: [[String]] = []
        var tiedIn: String?
        for barIndex in 0 ..< bars {
            let split = rng.chance(oneIn: 2)
            let pool = split ? ["H", "S", "C", "T"] : ["K", "S", "H", "P", "C", "T"]
            let first = voice(
                &rng, units: units, pool: pool, tiedIn: tiedIn, mayTuplet: true, mayTieOut: barIndex < bars - 1,
            )
            tiedIn = first.tiedOut
            var voices = [first.tokens.joined(separator: " ")]
            if split {
                let feet = voice(&rng, units: units, pool: ["K", "P"], tiedIn: nil, mayTuplet: false, mayTieOut: false)
                voices.append(feet.tokens.joined(separator: " "))
            }
            written.append(voices)
        }
        var score = RevoiceFixtures.score(written, meter: meter)
        for bar in 0 ..< bars {
            decorate(&score, bar: bar, &rng)
        }
        return score
    }

    /// The tokens of one voice that fills `units` sixteenths. `tiedIn` opens the voice with the previous bar's tied
    /// drum; the last hit is tied out, and its drum returned, when `mayTieOut` and the dice say so.
    private static func voice(
        _ rng: inout SplitMix64, units: Int, pool: [String], tiedIn: String?, mayTuplet: Bool, mayTieOut: Bool,
    ) -> (tokens: [String], tiedOut: String?) {
        var tokens: [String] = []
        var position = 0
        if let drum = tiedIn {
            let length = lengths[1 + rng.below(2)]
            tokens.append("~\(drum)/\(length.name)")
            position = length.units
        }
        while position < units {
            let remaining = units - position
            if mayTuplet, remaining >= 4, position % 4 == 0, rng.chance(oneIn: 16) {
                var members: [String] = []
                for _ in 0 ..< 3 {
                    members.append(rng.chance(oneIn: 4) ? "r/8" : "\(hit(&rng, pool))/8")
                }
                tokens += ["3:2[\(members[0])", members[1], "\(members[2])]"]
                position += 4
                continue
            }
            let fitting = lengths.filter { $0.units <= remaining }
            let length = fitting[rng.below(fitting.count)]
            tokens.append(rng.chance(oneIn: 3) ? "r/\(length.name)" : "\(hit(&rng, pool))/\(length.name)")
            position += length.units
        }
        guard mayTieOut, let last = tokens.last, !last.contains("r/"), !last.contains("+"), !last.contains("]"),
              rng.chance(oneIn: 8)
        else { return (tokens, nil) }
        tokens[tokens.count - 1] = last + "~"
        return (tokens, String(last.drop { $0 == "~" }.prefix { $0 != "/" }))
    }

    /// One drum, or two distinct ones struck together.
    private static func hit(_ rng: inout SplitMix64, _ pool: [String]) -> String {
        let first = pool[rng.below(pool.count)]
        guard rng.chance(oneIn: 4) else { return first }
        let second = pool[rng.below(pool.count)]
        return second == first ? first : "\(first)+\(second)"
    }

    /// Each of a roll, an accent and an annotation lands in about one bar in eight, on the first voice.
    private static func decorate(_ score: inout Score, bar: Int, _ rng: inout SplitMix64) {
        if rng.chance(oneIn: 8), let element = chordIndices(score, bar: bar, &rng) {
            score = RevoiceFixtures.editingChord(score, measure: bar, voice: 0, element: element) { chord in
                chord.tremolo = Tremolo(subtype: .r16, span: .single)
            }
        }
        if rng.chance(oneIn: 8), let element = chordIndices(score, bar: bar, &rng) {
            score = RevoiceFixtures.editingChord(score, measure: bar, voice: 0, element: element) { chord in
                chord.articulations.append(ChordArticulation(kind: .accent))
            }
        }
        // `inserting` rebuilds the voice without its tuplets, so only a voice that holds none takes an annotation.
        guard rng.chance(oneIn: 8), let voice = score[RevoiceFixtures.staff]?.measures[bar].voices.first,
              voice.tupletSpans.isEmpty
        else { return }
        let first = bar == 0 ? 1 : 0
        let index = first + rng.below(voice.elements.values.count - first + 1)
        let mark: VoiceElement = rng.chance(oneIn: 2)
            ? .dynamic(Dynamic(subtype: "f", velocity: 96)) : .sticking(Sticking(text: "R"))
        score = RevoiceFixtures.inserting(mark, into: score, measure: bar, voice: 0, at: index)
    }

    /// A random chord (not a rest) of bar `bar`'s first voice, as an element index.
    private static func chordIndices(_ score: Score, bar: Int, _ rng: inout SplitMix64) -> Int? {
        guard let voice = score[RevoiceFixtures.staff]?.measures[bar].voices.first else { return nil }
        let chords = voice.elements.values.enumerated().compactMap { index, element -> Int? in
            guard case let .chord(chord) = element, !chord.notes.isEmpty else { return nil }
            return index
        }
        return chords.isEmpty ? nil : chords[rng.below(chords.count)]
    }
}
