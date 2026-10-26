@testable import SheetMusicCore

/// Drum-staff fixtures for the `RevoiceDrumStaff` tests, written in a small text form so a bar reads as the design's
/// worked cases do (design 2026-10-26, drum voice conversion, §4.3).
///
/// Letters name GM drums: `K` 36 kick, `S` 38 snare, `H` 42 closed hi-hat, `P` 44 pedal hi-hat, `T` 47 tom,
/// `C` 49 crash, `R` 51 ride; any other pitch is written as its number. A voice is space-separated tokens: `H+K/8`
/// is a chord (letters in any order), `r/4` a rest, `r/m` a measure rest. The duration is `1 2 4 8 16 32 64`, each
/// `.` after it one dot. A leading `~` sets `tieBack = 1` and a trailing `~` sets `tieForward = 1` on every note of
/// the chord. `3:2[H/8 H/8 H/8]` is a tuplet of 3 in the time of 2, its members written at their nominal value and
/// stored scaled by normal/actual as a `.fraction`, as a decoded file stores them.
enum RevoiceFixtures {
    static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    static let division = 480
    /// The pad's hands-and-feet split for the GM kit: both kicks and the pedal hi-hat in voice 2.
    static let handsAndFeet: [Int: Int] = [35: 1, 36: 1, 44: 1]
    static let oneVoice: [Int: Int] = [:]

    static let pitches: [String: Int] = ["K": 36, "S": 38, "H": 42, "P": 44, "T": 47, "C": 49, "R": 51]
    private static let letters: [Int: String] = Dictionary(uniqueKeysWithValues: pitches.map { ($1, $0) })
    private static let durationNames: [(duration: NoteDuration, name: String)] = [
        (.whole, "1"), (.half, "2"), (.quarter, "4"), (.eighth, "8"), (.sixteenth, "16"), (.thirtySecond, "32"),
        (.sixtyFourth, "64"),
    ]
    /// Tonal pitch class by pitch class, sharps for the black keys.
    private static let tpcByPitchClass = [14, 21, 16, 23, 18, 13, 20, 15, 22, 17, 24, 19]

    // MARK: Building

    /// One drum part, one five-line percussion staff with `GMDrumset.entries`, division 480. `bars[measure][voice]`
    /// is a voice in the text form; bar 0's voice 0 opens with `.timeSignature(meter)`. `pickupTicks` makes bar 0
    /// that long and irregular — a pickup.
    static func score(
        _ bars: [[String]], meter: TimeSignature = .init(numerator: 4, denominator: 4), pickupTicks: Int? = nil,
    ) -> Score {
        let measures = bars.enumerated().map { barIndex, voices in
            var measure = Measure(voices: voices.enumerated().map { voiceIndex, tokens in
                voice(tokens, leading: barIndex == 0 && voiceIndex == 0 ? [.timeSignature(meter)] : [])
            })
            if barIndex == 0, let pickupTicks {
                measure.actualLength = Fraction(numerator: pickupTicks, denominator: 4 * division)
                measure.irregular = true
            }
            return measure
        }
        let drums = Staff(
            staffType: GMPercussion.staffTypeName, group: GMPercussion.staffGroup, defaultClefType: "PERC",
            measures: measures,
        )
        let instrument = Instrument(id: "drumset", useDrumset: true, drumset: GMDrumset.entries)
        return Score(
            division: division, parts: [Part(id: "P1", instrument: instrument, staves: [drums])],
            systemMeasures: IdentifiedArray(measures.map { _ in SystemMeasure() }),
        )
    }

    static func voice(_ tokens: String) -> Voice {
        voice(tokens, leading: [])
    }

    /// `tokens` after `leading` (which shifts the tuplets' member indices along).
    static func voice(_ tokens: String, leading: [VoiceElement]) -> Voice {
        var elements = leading
        var tuplets: [Tuplet] = []
        var open: (actual: Int, normal: Int, start: Int)?
        for var word in tokens.split(separator: " ") {
            if let bracket = word.firstIndex(of: "[") {
                let ratio = word[..<bracket].split(separator: ":").compactMap { Int($0) }
                precondition(ratio.count == 2, "a tuplet opens as actual:normal[ — \(word)")
                open = (actual: ratio[0], normal: ratio[1], start: elements.count)
                word = word[word.index(after: bracket)...]
            }
            let closes = word.hasSuffix("]")
            if closes { word = word.dropLast() }
            elements.append(element(word, tuplet: open.map { (actual: $0.actual, normal: $0.normal) }))
            if closes, let group = open {
                tuplets.append(Tuplet(
                    normalNotes: group.normal, actualNotes: group.actual, startIndex: group.start,
                    endIndex: elements.count - 1,
                ))
                open = nil
            }
        }
        return Voice(elements: elements, tuplets: tuplets)
    }

    private static func element(_ word: Substring, tuplet: (actual: Int, normal: Int)?) -> VoiceElement {
        var body = word
        let tiedBack = body.hasPrefix("~")
        if tiedBack { body = body.dropFirst() }
        let tiedForward = body.hasSuffix("~")
        if tiedForward { body = body.dropLast() }
        let parts = body.split(separator: "/")
        precondition(parts.count == 2, "a token is <drums>/<duration> — \(word)")
        let length = duration(parts[1], tuplet: tuplet)
        if parts[0] == "r" { return .rest(duration: length) }
        let notes = parts[0].split(separator: "+").map { name in
            let midi = pitch(name)
            return Note(
                pitch: midi, tpc: tpcByPitchClass[midi % 12], tieForward: tiedForward ? 1 : nil,
                tieBack: tiedBack ? 1 : nil,
            )
        }
        return .chord(Chord(duration: length, notes: ChordNotes(notes.sorted { $0.pitch < $1.pitch })))
    }

    private static func duration(_ text: Substring, tuplet: (actual: Int, normal: Int)?) -> NoteDuration {
        if text == "m" { return .measure }
        let dots = text.reversed().prefix { $0 == "." }.count
        let baseName = text.dropLast(dots)
        guard let base = durationNames.first(where: { $0.name == baseName })?.duration else {
            preconditionFailure("unknown duration \(text)")
        }
        let written = base.dotted(dots)
        guard let tuplet else { return written }
        let nominal = written.asFraction
        return .fraction(Fraction(
            numerator: nominal.numerator * tuplet.normal, denominator: nominal.denominator * tuplet.actual,
        ))
    }

    private static func pitch(_ name: Substring) -> Int {
        guard let midi = pitches[String(name)] ?? Int(name) else { preconditionFailure("unknown drum \(name)") }
        return midi
    }

    /// `score` with the chord at `element` of bar `measure`'s voice `voice` changed by `edit`. Element 0 of bar 0's
    /// voice 0 is the time signature, so that voice's first chord is element 1.
    static func editingChord(
        _ score: Score, measure: Int, voice: Int, element: Int, _ edit: (inout Chord) -> Void,
    ) -> Score {
        var result = score
        result.parts.updateValue(at: 0) { part in
            part.staves.updateValue(at: 0) { staff in
                staff.measures[measure].voices[voice].elements.updateValue(at: element) { slot in
                    guard case var .chord(chord) = slot else { preconditionFailure("element \(element) is no chord") }
                    edit(&chord)
                    slot = .chord(chord)
                }
            }
        }
        return result
    }

    // MARK: Reading back

    /// The text form of `voice`'s chords, rests and tuplets — every other element is left out. A chord's drums are
    /// written highest first (`H+K`, `C+K`, `H+S`), so a result reads as the design's cases do; `~` marks a chord
    /// whose every note carries the tie.
    static func tokens(of voice: Voice) -> String {
        let spans = voice.tupletSpans.filter(\.isResolved)
        var words: [String] = []
        for (index, element) in voice.elements.values.enumerated() {
            guard case let .chord(chord) = element else { continue }
            var scale = Fraction(numerator: 1, denominator: 1)
            var opening = ""
            var closing = ""
            for span in spans where (span.startIndex ... span.endIndex).contains(index) {
                scale = Fraction(
                    numerator: scale.numerator * span.actualNotes, denominator: scale.denominator * span.normalNotes,
                )
                if span.startIndex == index { opening += "\(span.actualNotes):\(span.normalNotes)[" }
                if span.endIndex == index { closing += "]" }
            }
            words.append(opening + word(for: chord, scale: scale) + closing)
        }
        return words.joined(separator: " ")
    }

    /// The text form of each voice of bar `measure` on `staff`.
    static func voices(_ score: Score, measure: Int) -> [String] {
        score[staff]?.measures[measure].voices.map(tokens(of:)) ?? []
    }

    private static func word(for chord: Chord, scale: Fraction) -> String {
        let length = name(of: chord.duration, scale: scale)
        guard !chord.notes.isEmpty else { return "r/\(length)" }
        let drums = chord.notes.map(\.pitch).sorted(by: >).map { letters[$0] ?? String($0) }
        let back = chord.notes.allSatisfy { $0.tieBack != nil } ? "~" : ""
        let forward = chord.notes.allSatisfy { $0.tieForward != nil } ? "~" : ""
        return "\(back)\(drums.joined(separator: "+"))/\(length)\(forward)"
    }

    /// `duration` read back to the value it is written as: a tuplet member through its ratio (`scale`).
    private static func name(of duration: NoteDuration, scale: Fraction) -> String {
        if case .measure = duration { return "m" }
        let stored = duration.asFraction
        let nominal = Fraction(
            numerator: stored.numerator * scale.numerator, denominator: stored.denominator * scale.denominator,
        )
        guard let split = NoteDuration.canonical(nominal).baseAndDots(),
              let base = durationNames.first(where: { $0.duration == split.base })?.name
        else { return "?\(nominal.numerator)/\(nominal.denominator)" }
        return base + String(repeating: ".", count: split.dots)
    }

    // MARK: Converting

    /// Assigns identifiers, then plans and applies `RevoiceDrumStaff` over `staff`. `plan` is nil when the command
    /// would change nothing.
    static func converted(
        _ score: Score, to map: [Int: Int], policy: RhythmSpellingPolicy = .default,
    ) throws -> (score: Score, plan: CompositeEditCommand?) {
        var result = score
        var ids = EIDAllocator()
        result.assignMissingIDs(using: &ids)
        let command = RevoiceDrumStaff(staff: staff, voiceForPitch: map, policy: policy)
        guard let plan = try command.plan(in: result, ids: ids) else { return (result, nil) }
        _ = try plan.apply(to: &result, ids: &ids)
        return (result, plan)
    }

    /// What `RevoiceBarPlanner` decides for bar `measure` of `staff` under `map`, read as the command reads it; nil
    /// when the score has no such staff.
    static func barPlan(
        _ score: Score, measure: Int, to map: [Int: Int], policy: RhythmSpellingPolicy = .default,
    ) -> RevoiceBarPlan? {
        guard let target = score[staff] else { return nil }
        let bar = RevoiceBar(staff: target, measureIndex: measure, division: score.division)
        return RevoiceBarPlanner.plan(bar, voiceForPitch: map, policy: policy)
    }
}
