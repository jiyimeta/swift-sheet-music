import SheetMusicCore
import Testing

/// One step of a microtonal grid — a quarter tone, a twelfth of a tone — spelled in the notation that grid is written
/// in (`Note.shifted(oneStepOf:up:in:)`).
@Suite("Microtonal step")
struct MicrotonalStepTests {
    // TPC: 13=F 14=C 15=G 16=D 17=A 18=E 19=B, +7 per sharp, −7 per flat.
    private static let a4 = Note(pitch: 69, tpc: 17)
    private static let b4 = Note(pitch: 71, tpc: 19)

    /// The notes `steps` presses away from `start`, each spelled as (pitch, tpc, accidental).
    private func walk(
        from start: Note, _ notation: MicrotonalNotation, up: Bool, steps: Int, keySig: Int = 0,
    ) -> [Spelled] {
        var note = start
        var out: [Spelled] = []
        for _ in 0 ..< steps {
            guard let next = note.shifted(oneStepOf: notation, up: up, in: keySig) else { break }
            out.append(Spelled(next))
            note = next
        }
        return out
    }

    /// `note` one step of `notation` away, spelled as (pitch, tpc, accidental).
    private func step(_ note: Note, _ notation: MicrotonalNotation, up: Bool, keySig: Int = 0) -> Spelled? {
        note.shifted(oneStepOf: notation, up: up, in: keySig).map(Spelled.init)
    }

    private struct Spelled: Equatable, CustomStringConvertible {
        let pitch: Int
        let tpc: Int
        let accidental: Accidental?
        init(_ pitch: Int, _ tpc: Int, _ accidental: Accidental?) {
            self.pitch = pitch
            self.tpc = tpc
            self.accidental = accidental
        }

        init(_ note: Note) {
            self.init(note.pitch, note.tpc, note.accidental)
        }

        var description: String {
            "(\(pitch), \(tpc), \(accidental.map { "\($0)" } ?? "nil"))"
        }
    }

    @Test func `quarter tones up from A climb the sharp side and reach B`() {
        #expect(walk(from: Self.a4, .steinZimmermann, up: true, steps: 4) == [
            Spelled(69, 17, .sharpSlash),
            Spelled(70, 24, .sharp),
            Spelled(69, 17, .sharpSlash4),
            Spelled(71, 19, nil),
        ])
    }

    @Test func `quarter tones down from B descend the flat side and reach A`() {
        #expect(walk(from: Self.b4, .steinZimmermann, up: false, steps: 4) == [
            Spelled(71, 19, .mirroredFlat),
            Spelled(70, 12, .flat),
            Spelled(71, 19, .mirroredFlat2),
            Spelled(69, 17, nil),
        ])
    }

    /// A plain note keeps its letter: B♭ a quarter tone up is B half-flat, not A three-quarter-sharp.
    @Test func `a quarter tone from a plain note keeps its letter`() {
        let bFlat = Note(pitch: 70, tpc: 12, accidental: .flat)
        #expect(step(bFlat, .steinZimmermann, up: true) == Spelled(71, 19, .mirroredFlat))
        let fSharp = Note(pitch: 66, tpc: 20, accidental: .sharp)
        #expect(step(fSharp, .steinZimmermann, up: false) == Spelled(65, 13, .sharpSlash))
    }

    /// Gould's arrows put the arrow on the accidental the note already has: A♮↑, A♯, A♯↑ — and on the way down
    /// B♮↓, B♭, B♭↓.
    @Test func `a Gould arrow rides on the accidental the note already has`() {
        #expect(walk(from: Self.a4, .gouldArrows, up: true, steps: 4) == [
            Spelled(69, 17, .naturalArrowUp),
            Spelled(70, 24, .sharp),
            Spelled(69, 17, .sharpArrowUp),
            Spelled(71, 19, nil),
        ])
        #expect(walk(from: Self.b4, .gouldArrows, up: false, steps: 4) == [
            Spelled(71, 19, .naturalArrowDown),
            Spelled(70, 12, .flat),
            Spelled(71, 19, .flatArrowDown),
            Spelled(69, 17, nil),
        ])
        let aSharp = Note(pitch: 70, tpc: 24, accidental: .sharp)
        #expect(step(aSharp, .gouldArrows, up: false) == Spelled(69, 17, .sharpArrowDown))
        let bFlat = Note(pitch: 70, tpc: 12, accidental: .flat)
        #expect(step(bFlat, .gouldArrows, up: true) == Spelled(71, 19, .flatArrowUp))
    }

    @Test func `twelfths of a tone up from A pass A sharp and reach B`() {
        #expect(walk(from: Self.a4, .wyschnegradsky, up: true, steps: 12) == [
            Spelled(69, 17, .oneTwelfthSharp),
            Spelled(69, 17, .twoTwelfthSharp),
            Spelled(69, 17, .threeTwelfthSharp),
            Spelled(69, 17, .fourTwelfthSharp),
            Spelled(69, 17, .fiveTwelfthSharp),
            Spelled(70, 24, .sharp),
            Spelled(69, 17, .sevenTwelfthSharp),
            Spelled(69, 17, .eightTwelfthSharp),
            Spelled(69, 17, .nineTwelfthSharp),
            Spelled(69, 17, .tenTwelfthSharp),
            Spelled(69, 17, .elevenTwelfthSharp),
            Spelled(71, 19, nil),
        ])
    }

    @Test func `twelfths of a tone down from B pass B flat and reach A`() {
        #expect(walk(from: Self.b4, .wyschnegradsky, up: false, steps: 12) == [
            Spelled(71, 19, .oneTwelfthFlat),
            Spelled(71, 19, .twoTwelfthFlat),
            Spelled(71, 19, .threeTwelfthFlat),
            Spelled(71, 19, .fourTwelfthFlat),
            Spelled(71, 19, .fiveTwelfthFlat),
            Spelled(70, 12, .flat),
            Spelled(71, 19, .sevenTwelfthFlat),
            Spelled(71, 19, .eightTwelfthFlat),
            Spelled(71, 19, .nineTwelfthFlat),
            Spelled(71, 19, .tenTwelfthFlat),
            Spelled(71, 19, .elevenTwelfthFlat),
            Spelled(69, 17, nil),
        ])
    }

    /// Spartan Sagittal spells at most five twelfths on a letter, so past the semitone the step moves to the next one.
    @Test func `a Sagittal step moves to the next letter where its glyphs run out`() {
        #expect(walk(from: Self.a4, .sagittal, up: true, steps: 12) == [
            Spelled(69, 17, .sagittal5CommaUp),
            Spelled(69, 17, .sagittal7CommaUp),
            Spelled(69, 17, .sagittal11MediumDiesisUp),
            Spelled(69, 17, .sagittalSharp7CDown),
            Spelled(69, 17, .sagittalSharp5CDown),
            Spelled(70, 24, .sharp),
            Spelled(71, 19, .sagittalFlat5CUp),
            Spelled(71, 19, .sagittalFlat7CUp),
            Spelled(71, 19, .sagittal11MediumDiesisDown),
            Spelled(71, 19, .sagittal7CommaDown),
            Spelled(71, 19, .sagittal5CommaDown),
            Spelled(71, 19, nil),
        ])
    }

    /// A glyph from another grid sits between this grid's points; a step goes to the nearest point in its direction.
    @Test func `a note off the grid steps to the nearest grid point in that direction`() {
        // E koron sounds 67 cents low: between E♭ (−100) and E half-flat (−50).
        let eKoron = Note(pitch: 64, tpc: 18, accidental: .koron)
        #expect(step(eKoron, .steinZimmermann, up: true) == Spelled(64, 18, .mirroredFlat))
        #expect(step(eKoron, .steinZimmermann, up: false) == Spelled(63, 11, .flat))
    }

    /// A quarter tone is three twelfths, so a twelfth step from a Stein glyph lands on the Wyschnegradsky glyph beside
    /// it.
    @Test func `a twelfth step from a quarter-tone glyph lands beside it`() {
        let aQuarterSharp = Note(pitch: 69, tpc: 17, accidental: .sharpSlash)
        #expect(step(aQuarterSharp, .wyschnegradsky, up: true)
            == Spelled(69, 17, .fourTwelfthSharp))
        #expect(step(aQuarterSharp, .wyschnegradsky, up: false)
            == Spelled(69, 17, .twoTwelfthSharp))
    }

    /// Landing back on a semitone spells it in the key, as ↑ / ↓ do: under F major the B the walk reaches carries ♮.
    @Test func `a semitone the step lands on is spelled in the key`() {
        let aThreeQuarterSharp = Note(pitch: 69, tpc: 17, accidental: .sharpSlash4)
        #expect(step(aThreeQuarterSharp, .steinZimmermann, up: true, keySig: -1)
            == Spelled(71, 19, .natural))
        let bHalfFlat = Note(pitch: 71, tpc: 19, accidental: .mirroredFlat)
        #expect(step(bHalfFlat, .steinZimmermann, up: false, keySig: -1)
            == Spelled(70, 12, nil))
    }

    @Test func `a step past MIDI's range is refused`() {
        #expect(Note(pitch: 127, tpc: 15).shifted(oneStepOf: .steinZimmermann, up: true) == nil)
        #expect(Note(pitch: 0, tpc: 14).shifted(oneStepOf: .wyschnegradsky, up: false) == nil)
    }

    @Test func `each notation claims its own glyphs`() {
        #expect(MicrotonalNotation(writing: .sharpSlash4) == .steinZimmermann)
        #expect(MicrotonalNotation(writing: .flatArrowUp) == .gouldArrows)
        #expect(MicrotonalNotation(writing: .sevenTwelfthFlat) == .wyschnegradsky)
        #expect(MicrotonalNotation(writing: .sagittal35LargeDiesisUp) == .sagittal)
        #expect(MicrotonalNotation(writing: .sharp) == nil)
        #expect(MicrotonalNotation(writing: .koron) == nil)
        #expect(MicrotonalNotation.steinZimmermann.step == .quarterTone)
        #expect(MicrotonalNotation.sagittal.step == .twelfthTone)
        #expect(MicrotonalStep.quarterTone.defaultNotation == .steinZimmermann)
        #expect(MicrotonalStep.twelfthTone.defaultNotation == .wyschnegradsky)
    }
}
