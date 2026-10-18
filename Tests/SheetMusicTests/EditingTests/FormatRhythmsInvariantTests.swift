import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
import Testing

/// What a gate looked at, so a green run can be told from an empty one.
struct FormatRhythmsGateCounts {
    var scores = 0
    var skipped = 0
    var barVoices = 0
    var changedBarVoices = 0
    var runs = 0
    /// Scores whose instrument default gate time was below 100 and was raised to 100 for the sound comparison (see
    /// `FormatRhythmsGate.withFullGate`).
    var gateNeutralized = 0
}

/// Shared by the invariant and corpus gates: tokenizing a voice the way the Python reference checker does, applying a
/// plan, and the tie-pairing count.
enum FormatRhythmsGate {
    static func applied(
        _ score: Score, policy: RhythmSpellingPolicy,
    ) throws -> (score: Score, changedBarVoices: Int, secondPlan: CompositeEditCommand?) {
        var formatted = score
        var ids = EIDAllocator()
        formatted.assignMissingIDs(using: &ids)
        let command = FormatRhythms(scope: .score, policy: policy)
        guard let plan = try command.plan(in: formatted, ids: ids) else {
            return (formatted, 0, nil)
        }
        _ = try plan.apply(to: &formatted, ids: &ids)
        return try (formatted, plan.commands.count, command.plan(in: formatted, ids: ids))
    }

    /// `score` with every instrument's default articulation at gate time 100.
    ///
    /// `MidiRenderer` applies an instrument's gate time (a percentage of the note that sounds) to the LAST link of a
    /// tie chain only, so on an instrument whose default gate is below 100 the release of a note depends on how it is
    /// spelled: a dotted half is released at 95% of its length, the same note as half ~ quarter at the head's full
    /// length plus 95% of the tail's. `FormatRhythms` re-spells durations, so on such a score the render moves by
    /// that gate remainder. The comparison here removes that one renderer input and holds everything else exact;
    /// `gateTimeBreaksSoundOnShortenedInstruments` pins the gap itself.
    static func withFullGate(_ score: Score) -> Score {
        var result = score
        result.parts.mapValues { part in
            var part = part
            for index in part.instrument.articulations.indices where part.instrument.articulations[index].name == nil {
                part.instrument.articulations[index].gateTime = 100
            }
            return part
        }
        return result
    }

    /// `score` without the preserved `<Beam>` markers MuseScore writes for a hand-set beam mode. Every stream element
    /// is a wall to a tie merge (design §4.2), a preserved beam marker included, so a fixture carrying them keeps its
    /// tied chains as written; MuseScore's own regroup ignores them. The corpus gate strips them from its INPUT so it
    /// measures the splitter and the span rules rather than that wall.
    static func withoutBeamMarkers(_ score: Score) -> Score {
        editingVoices(score) { voice in
            voice.elements.removeAll {
                if case let .preserved(xml) = $0 { xml.name == "Beam" } else { false }
            }
        }
    }

    /// `score` with every chord's articulations cleared and every fermata removed. A chord carrying an articulation,
    /// or sitting beside a fermata, is left as written (design §4.1: the tie chain's gate comes from its articulation,
    /// a fermata's hold is measured from the neighbouring chord), where MuseScore's regroup re-spells it regardless.
    static func withoutArticulationsAndFermatas(_ score: Score) -> Score {
        editingVoices(score) { voice in
            voice.elements.removeAll {
                if case .fermata = $0 { true } else { false }
            }
            voice.elements.mapValues { element in
                guard case var .chord(chord) = element else { return element }
                chord.articulations = []
                return .chord(chord)
            }
        }
    }

    private static func editingVoices(_ score: Score, _ edit: (inout Voice) -> Void) -> Score {
        var result = score
        result.parts.mapValues { part in
            var part = part
            part.staves.mapValues { staff in
                var staff = staff
                for measureIndex in staff.measures.indices {
                    for voiceIndex in staff.measures[measureIndex].voices.indices {
                        edit(&staff.measures[measureIndex].voices[voiceIndex])
                    }
                }
                return staff
            }
            return part
        }
        return result
    }

    static func barVoiceCount(_ score: Score) -> Int {
        score.allStaves.reduce(0) { $0 + $1.staff.measures.reduce(0) { $0 + $1.voices.count } }
    }

    /// Notes whose tie flag points at no partner, by `TiePlanner`'s adjacency rule.
    static func danglingTies(in score: Score) -> Int {
        var count = 0
        for (address, staff) in score.allStaves {
            for (measureIndex, measure) in staff.measures.enumerated() {
                for (voiceIndex, voice) in measure.voices.enumerated() {
                    for (elementIndex, element) in voice.elements.values.enumerated() {
                        guard case let .chord(chord) = element else { continue }
                        for (noteIndex, note) in chord.notes.enumerated() {
                            let id = NoteID(
                                staff: address, measureIndex: measureIndex, voiceIndex: voiceIndex,
                                elementIndex: elementIndex, noteIndexInChord: noteIndex,
                            )
                            if note.tieForward != nil, TiePlanner.tiedNote(after: id, in: score) == nil { count += 1 }
                            if note.tieBack != nil, TiePlanner.tiedNote(before: id, in: score) == nil { count += 1 }
                        }
                    }
                }
            }
        }
        return count
    }

    // MARK: Tokens

    private static let names: [(NoteDuration, String)] = [
        (.whole, "whole"), (.half, "half"), (.quarter, "quarter"), (.eighth, "eighth"), (.sixteenth, "16th"),
        (.thirtySecond, "32nd"), (.sixtyFourth, "64th"), (.oneTwentyEighth, "128th"), (.twoFiftySixth, "256th"),
    ]

    private static func name(of duration: NoteDuration, scale: (num: Int, den: Int)) -> String {
        if case .measure = duration { return "measure" }
        let whole = duration.asFraction
        let nominal = Fraction(numerator: whole.numerator * scale.num, denominator: whole.denominator * scale.den)
        guard let split = NoteDuration.canonical(nominal).baseAndDots(),
              let base = names.first(where: { $0.0 == split.base })?.1
        else { return "?\(nominal.numerator)/\(nominal.denominator)" }
        return base + String(repeating: ".", count: split.dots)
    }

    /// One token per timed element, in the Python checker's spelling: `R:`/`C:`, the nominal duration name (a tuplet
    /// member is read back through its ratio), `~` when every note ties forward, `(t)` inside a tuplet.
    static func tokens(of voice: Voice) -> [String] {
        let spans = voice.tupletSpans.filter(\.isResolved)
        var result: [String] = []
        for (index, element) in voice.elements.values.enumerated() {
            guard case let .chord(chord) = element else { continue }
            var scale = (num: 1, den: 1)
            var inTuplet = false
            for span in spans where (span.startIndex ... span.endIndex).contains(index) {
                scale = (scale.num * span.actualNotes, scale.den * span.normalNotes)
                inTuplet = true
            }
            let isRest = chord.notes.isEmpty
            let tied = !isRest && chord.notes.allSatisfy { $0.tieForward != nil }
            result.append(
                "\(isRest ? "R" : "C"):\(name(of: chord.duration, scale: scale))\(tied ? "~" : "")"
                    + (inTuplet ? "(t)" : ""),
            )
        }
        return result
    }
}

@Suite("FormatRhythms invariants")
struct FormatRhythmsInvariantTests {
    static let policies: [(label: String, policy: RhythmSpellingPolicy)] = [
        ("default", .default), ("museScore", .museScore),
    ] + RhythmSpellingPolicy.DotLevel.allCases.map { level in
        ("default/dots=\(level)", RhythmSpellingPolicy(
            dotLevel: level, midBarSyncopations: .split, beatCrossingRests: .keepWritten,
        ))
    }

    /// Every top-level `.mscx` fixture; the nested folders hold per-feature corpora with their own gates.
    static func topLevelFixtures() -> [URL] {
        guard let root = TestResources.resourceURL?.standardizedFileURL else { return [] }
        return MSCXFixtureLoader.allMSCXURLs().filter { $0.deletingLastPathComponent().standardizedFileURL == root }
    }

    @Test("sound, idempotence and tie pairing hold over every fixture score under every policy")
    func invariants() throws {
        var counts = FormatRhythmsGateCounts()
        for url in Self.topLevelFixtures() {
            guard let parsed = try? MSCXParser.parse(contentsOf: url) else {
                counts.skipped += 1
                continue
            }
            let score = FormatRhythmsGate.withFullGate(parsed)
            if score != parsed { counts.gateNeutralized += 1 }
            guard let before = try? MidiRenderer.render(score: score) else {
                counts.skipped += 1
                continue
            }
            counts.scores += 1
            let danglingBefore = FormatRhythmsGate.danglingTies(in: score)
            for (label, policy) in Self.policies {
                let result = try FormatRhythmsGate.applied(score, policy: policy)
                counts.runs += 1
                counts.barVoices += FormatRhythmsGate.barVoiceCount(score)
                counts.changedBarVoices += result.changedBarVoices
                let after = try MidiRenderer.render(score: result.score)
                #expect(after == before, "sound: \(url.lastPathComponent) under \(label)")
                #expect(result.secondPlan == nil, "idempotence: \(url.lastPathComponent) under \(label)")
                #expect(
                    FormatRhythmsGate.danglingTies(in: result.score) <= danglingBefore,
                    "ties paired: \(url.lastPathComponent) under \(label)",
                )
            }
        }
        Issue.record(
            Comment(rawValue: "gate coverage: \(counts)"), severity: .warning,
        )
        // Floors a little under what the gate saw when they were set (2026-10-18: 101 scores, 0 skipped, 38 changed
        // bar-voices over 606 runs). `> 0` would stay green if a decoder change or a too-eager wall emptied the gate
        // down to one score or one edit; these turn red instead, and are lowered only with a reason.
        #expect(counts.scores >= 95, "fixtures parsed and rendered: \(counts.scores)")
        #expect(counts.skipped == 0, "fixtures skipped: \(counts.skipped)")
        #expect(counts.changedBarVoices >= 30, "bar-voices the gate saw change: \(counts.changedBarVoices)")
    }

    /// The gap `withFullGate` steps around, pinned so it turns red (and the workaround can go) when the formatter
    /// learns to leave such spans alone or the renderer gates a chain as a whole.
    @Test("a split changes the release on an instrument whose default gate time is below 100")
    func gateTimeBreaksSoundOnShortenedInstruments() throws {
        let url = try #require(TestResources.url(forResource: "testMutedUnison", withExtension: "mscx"))
        let score = try MSCXParser.parse(contentsOf: url)
        let before = try MidiRenderer.render(score: score)
        let noDots = RhythmSpellingPolicy(dotLevel: .none, midBarSyncopations: .split, beatCrossingRests: .keepWritten)
        let result = try FormatRhythmsGate.applied(score, policy: noDots)
        #expect(result.changedBarVoices > 0)
        let after = try MidiRenderer.render(score: result.score)
        withKnownIssue("renderer gates the last tie link only") { #expect(after == before) }
    }

    @Test(
        "owner score: sound and idempotent under the default policy, dumped for the reference diff",
        .enabled(if: ProcessInfo.processInfo.environment["SM_FORMAT_RHYTHMS_SCORE"] != nil),
    )
    func ownerScore() throws {
        let env = ProcessInfo.processInfo.environment
        let path = try #require(env["SM_FORMAT_RHYTHMS_SCORE"])
        let score = try MSCZReader.parse(contentsOf: URL(fileURLWithPath: path))
        let before = try MidiRenderer.render(score: score)
        let result = try FormatRhythmsGate.applied(score, policy: .default)
        #expect(try MidiRenderer.render(score: result.score) == before, "sound")
        #expect(result.secondPlan == nil, "idempotence")
        #expect(FormatRhythmsGate.danglingTies(in: result.score) <= FormatRhythmsGate.danglingTies(in: score))
        #expect(result.changedBarVoices > 0)

        guard let dump = env["SM_FORMAT_RHYTHMS_DUMP"] else { return }
        var lines: [String] = []
        for (staffIndex, entry) in result.score.allStaves.enumerated() {
            let original = score.allStaves[staffIndex].staff
            for (measureIndex, measure) in entry.staff.measures.enumerated() {
                for (voiceIndex, voice) in measure.voices.enumerated() {
                    let now = FormatRhythmsGate.tokens(of: voice)
                    guard now != FormatRhythmsGate.tokens(of: original.measures[measureIndex].voices[voiceIndex])
                    else { continue }
                    let place = "m\(measureIndex + 1) s\(staffIndex + 1) v\(voiceIndex + 1)"
                    lines.append("\(place): \(now.joined(separator: " "))")
                }
            }
        }
        try (lines.joined(separator: "\n") + "\n").write(toFile: dump, atomically: true, encoding: .utf8)
        Issue.record(
            Comment(rawValue: "owner score: \(lines.count) changed voice-measures, \(result.changedBarVoices) edits"),
            severity: .warning,
        )
    }
}
