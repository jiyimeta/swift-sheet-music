@testable import SheetMusicCore
@testable import SheetMusicMSCX
import Testing

/// Edits that invent durations spell them against the bar's meter (`BarMeter`), the way `FormatRhythms` would under
/// `.default`. Each case below is one `alignedDurations` got wrong: it knew no meter and never wrote a dot.
@Suite("Meter-aware edit spelling")
struct MeterAwareEditSpellingTests {
    typealias Bars = FormatRhythmsBarPlannerTests
    typealias Format = FormatRhythmsTests

    static let division = 480

    static func staff(_ measures: [Measure]) -> Staff {
        Staff(measures: measures)
    }

    static func timeSignature(_ numerator: Int, _ denominator: Int) -> VoiceElement {
        .timeSignature(TimeSignature(numerator: numerator, denominator: denominator))
    }

    // MARK: BarMeter

    @Test("the meter in force is the last signature at or before the bar, 4/4 before the first")
    func meterInForce() {
        let staff = Self.staff([
            Format.bar([Bars.note(1, 1)]),
            Format.bar([Self.timeSignature(6, 8), Bars.note(3, 4)]),
            Format.bar([Bars.note(3, 4)]),
        ])
        let first = BarMeter(staff: staff, measureIndex: 0, barTicks: 1920, division: Self.division)
        #expect(first.numerator == 4 && first.denominator == 4)
        let third = BarMeter(staff: staff, measureIndex: 2, barTicks: 1440, division: Self.division)
        #expect(third.numerator == 6 && third.denominator == 8)
        // Three eighth rests from the downbeat of 6/8 are one dotted-quarter rest; `alignedDurations` wrote a quarter
        // and an eighth.
        #expect(third.durations(forTicks: 720, at: 0, isRest: true) == [NoteDuration.quarter.dotted(1)])
        #expect(
            DurationChangeAlgorithm.alignedDurations(forTicks: 720, rtickStart: 0, division: Self.division)
                == [.quarter, .eighth],
        )
    }

    @Test("a pickup is right-aligned and never a measure rest; a short final bar is left-aligned")
    func pickupAlignment() {
        let pickup = Measure(
            voices: [Voice(elements: [Self.timeSignature(4, 4), Bars.rest(1, 4)])],
            actualLength: Fraction(numerator: 1, denominator: 4),
        )
        let short = Measure(
            voices: [Voice(elements: [Bars.rest(3, 4)])], actualLength: Fraction(numerator: 3, denominator: 4),
        )
        let staff = Self.staff([pickup, Format.bar([Bars.note(1, 1)]), short])
        let first = BarMeter(staff: staff, measureIndex: 0, barTicks: 480, division: Self.division)
        #expect(first.isPickup)
        #expect(first.pickupOffset == 1440)
        #expect(first.durations(forTicks: 480, at: 0, isRest: true) == [.quarter])
        // A half note opening a 5/8 pickup in 4/4 starts on the "and" of beat 2 — the spec's first owner example,
        // an eighth tied to a dotted quarter — where the same half at the start of a left-aligned bar is one half.
        let fiveEighths = BarMeter(
            numerator: 4, denominator: 4, barTicks: 1200, isPickup: true, division: Self.division,
        )
        #expect(
            fiveEighths.durations(forTicks: 960, at: 0, isRest: false) == [.eighth, NoteDuration.quarter.dotted(1)],
        )
        let leftAligned = BarMeter(
            numerator: 4, denominator: 4, barTicks: 1200, isPickup: false, division: Self.division,
        )
        #expect(leftAligned.durations(forTicks: 960, at: 0, isRest: false) == [.half])
        let last = BarMeter(staff: staff, measureIndex: 2, barTicks: 1440, division: Self.division)
        #expect(!last.isPickup)
        #expect(last.durations(forTicks: 1440, at: 0, isRest: true) == [.measure])
    }

    @Test("an unreadable meter falls back to alignedDurations instead of failing the edit")
    func fallback() {
        let bar = BarMeter(numerator: 3, denominator: 7, barTicks: 1920, isPickup: false, division: Self.division)
        #expect(
            bar.durations(forTicks: 720, at: 0, isRest: true)
                == DurationChangeAlgorithm.alignedDurations(forTicks: 720, rtickStart: 0, division: Self.division),
        )
    }

    // MARK: Paths

    @Test("shortening a 6/8 dotted half leaves rests that show the beat")
    func durationChangeInCompoundMeter() throws {
        var score = Format.score([[Format.bar([Self.timeSignature(6, 8), Bars.note(3, 4)])]])
        _ = try SetChordDuration(at: Format.slot(element: 1), duration: .eighth).apply(to: &score)
        // Inside a compound beat a rest shows each eighth (MuseScore's rule); the second beat is one dotted-quarter
        // rest. `alignedDurations` wrote eighth, quarter, quarter — a rest across the beat.
        #expect(Format.durations(score) == [.eighth, .eighth, .eighth, NoteDuration.quarter.dotted(1)])
    }

    @Test("splitting a rest in a pickup reads the pickup right-aligned")
    func splitRestInPickup() throws {
        let pickup = Measure(
            voices: [Voice(elements: [Self.timeSignature(4, 4), Bars.rest(1, 2)])],
            actualLength: Fraction(numerator: 1, denominator: 2),
        )
        var score = Format.score([[pickup, Format.bar([Bars.note(1, 1)])]])
        var ids = EIDAllocator()
        score.assignMissingIDs(using: &ids)
        // The pickup's half rest is beats 3–4. Split after a sixteenth it leaves 7/16 from the sixteenth after beat 3:
        // a sixteenth and an eighth to beat 4 (a rest takes no dot in 4/4) and a quarter, not the left-aligned
        // spelling of a bar's first beats.
        _ = try SplitRest(at: Format.slot(element: 1), tickOffset: 120).apply(to: &score, ids: &ids)
        #expect(Format.durations(score) == [.sixteenth, .sixteenth, .eighth, .quarter])
    }

    // MARK: Accidentals

    @Test("a tied continuation written by makeChordChain prints no accidental; the head and a fresh attack keep it")
    func chainContinuationsDropTheAccidental() throws {
        let source = Chord(duration: .half, notes: [
            Note(pitch: 61, tpc: 21, accidental: .sharp, accidentalBracket: .parenthesis, accidentalRole: .user),
        ])
        for ownership in [DurationChangeAlgorithm.OnsetOwnership.headIsOnset, .allContinuation] {
            let chain = DurationChangeAlgorithm.makeChordChain(
                from: source, durations: [.quarter, .eighth, .eighth], onsetOwnership: ownership,
            )
            let notes = chain.compactMap { element -> Note? in
                if case let .chord(chord) = element { chord.notes[0] } else { nil }
            }
            try #require(notes.count == 3)
            // The first piece has no tie in, so it is an attack and shows what the source showed.
            #expect(notes[0].accidental == .sharp)
            #expect(notes[0].accidentalRole == .user)
            for note in notes.dropFirst() {
                #expect(note.tieBack == 1)
                #expect(note.accidental == nil)
                #expect(note.accidentalBracket == AccidentalBracket.none)
                #expect(note.accidentalRole == .auto)
                #expect(note.pitch == 61 && note.tpc == 21)
            }
        }
    }

    // MARK: Agreement with Format Rhythms

    static let meters: [(Int, Int)] = [(2, 4), (3, 4), (4, 4), (2, 2), (3, 8), (6, 8), (9, 8), (12, 8), (5, 8), (7, 8)]

    @Test(
        "in every meter family, the rests a shortened bar-long note leaves are what Format Rhythms would write there",
        arguments: meters,
    )
    func shortenedLeftoversAgreeInEveryMeter(meter: (Int, Int)) throws {
        let barTicks = meter.0 * 4 * Self.division / meter.1
        var compared = 0
        // A bar-long note shortened to every sixteenth-multiple length: the leftover starts on every sixteenth.
        for kept in stride(from: 120, to: barTicks, by: 120) {
            var score = Format.score([[Format.bar([
                Self.timeSignature(meter.0, meter.1),
                .chord(Chord(duration: .canonical(Fraction(ticks: barTicks, division: Self.division)), notes: [
                    Note(pitch: 60, tpc: 14),
                ])),
            ])]])
            let target = NoteDuration.canonical(Fraction(ticks: kept, division: Self.division))
            guard target.baseAndDots() != nil,
                  (try? SetChordDuration(at: Format.slot(element: 1), duration: target).apply(to: &score)) != nil,
                  let staff = score[Format.staff0]
            else { continue }
            compared += 1
            let facts = try #require(
                FormatRhythmsBars(staff: staff, division: Self.division)
                    .facts(at: 0, window: kept ..< barTicks, protectedOnsets: []),
            )
            #expect(
                FormatRhythmsBarPlanner.respell(staff.measures[0].voices[0], facts: facts, policy: .default) == nil,
                "\(meter.0)/\(meter.1), note kept \(kept) ticks: \(Format.durations(score))",
            )
        }
        #expect(compared > 0)
    }

    @Test("over every fixture, the rests a shortened chord leaves are what Format Rhythms would write there")
    func shortenedLeftoversAreAlreadyFormatted() {
        var edits = 0
        var disagreements: [String] = []
        for url in FormatRhythmsInvariantTests.topLevelFixtures() {
            guard var score = try? MSCXParser.parse(contentsOf: url) else { continue }
            var ids = EIDAllocator()
            score.assignMissingIDs(using: &ids)
            let division = score.division
            for (address, staff) in score.allStaves {
                let lengths = staff.measures.effectiveMeasureDurations()
                // The first bar-voice chord of each bar longer than an eighth, outside tuplets, is shortened to an
                // eighth; the leftover rests are then checked against the formatter over exactly their window.
                for measureIndex in staff.measures.indices.prefix(12) {
                    let voice = staff.measures[measureIndex].voices[0]
                    var tick = 0
                    var target: (index: Int, tick: Int, ticks: Int)?
                    for (index, element) in voice.elements.enumerated() {
                        defer { tick += element.cursorAdvance(division: division, in: lengths[measureIndex]) }
                        guard target == nil, case let .chord(chord) = element, !chord.notes.isEmpty,
                              !voice.tupletSpans.contains(where: { $0.startIndex <= index && index <= $0.endIndex })
                        else { continue }
                        let ticks = chord.duration.resolved(in: lengths[measureIndex]).ticks(division: division)
                        if ticks > division / 2 { target = (index, tick, ticks) }
                    }
                    guard let target else { continue }
                    var edited = score
                    let location = VoiceElementID(
                        staff: address, measureIndex: measureIndex, voiceIndex: 0, elementIndex: target.index,
                    )
                    guard (try? SetChordDuration(at: location, duration: .eighth).apply(to: &edited, ids: &ids))
                        != nil
                    else { continue }
                    edits += 1
                    guard let editedStaff = edited[address] else { continue }
                    let bars = FormatRhythmsBars(staff: editedStaff, division: division)
                    let leftover = (target.tick + division / 2) ..< (target.tick + target.ticks)
                    guard let facts = bars.facts(at: measureIndex, window: leftover, protectedOnsets: []) else {
                        continue
                    }
                    if FormatRhythmsBarPlanner.respell(
                        editedStaff.measures[measureIndex].voices[0], facts: facts, policy: .default,
                    ) != nil {
                        disagreements.append("\(url.lastPathComponent) \(address) m\(measureIndex + 1)")
                    }
                }
            }
        }
        #expect(edits >= 100, "edits made: \(edits)")
        #expect(disagreements.isEmpty, "\(disagreements.prefix(10))")
    }
}
