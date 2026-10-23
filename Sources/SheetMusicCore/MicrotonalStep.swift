import SheetMusicFoundation

/// The grid a microtonal pitch key steps along: how many parts it divides the semitone into.
public enum MicrotonalStep: Sendable, CaseIterable {
    /// 24-EDO: two steps to the semitone, 50 cents each.
    case quarterTone
    /// 72-EDO: six steps to the semitone, a twelfth of a tone (about 17 cents) each.
    case twelfthTone

    public var divisionsPerSemitone: Int {
        switch self {
        case .quarterTone: 2
        case .twelfthTone: 6
        }
    }

    /// The notation a step on this grid is written in when nothing says otherwise.
    public var defaultNotation: MicrotonalNotation {
        switch self {
        case .quarterTone: .steinZimmermann
        case .twelfthTone: .wyschnegradsky
        }
    }
}

/// A notation that spells every point of one `MicrotonalStep` grid with a glyph of its own.
///
/// The cents each glyph stands for are `Accidental.centOffset` — MuseScore's — so a stepped note sounds where the
/// grid says it is.
public enum MicrotonalNotation: Sendable, CaseIterable {
    /// Stein-Zimmermann's half-sharp, sesquisharp, half-flat and sesquiflat.
    case steinZimmermann
    /// Gould's arrows: a quarter-tone arrow on a ♮, ♯ or ♭.
    case gouldArrows
    /// Wyschnegradsky's twelfths of a tone, one to eleven either way.
    case wyschnegradsky
    /// Spartan Sagittal, which spells up to five twelfths either way of a letter.
    case sagittal

    public var step: MicrotonalStep {
        switch self {
        case .steinZimmermann, .gouldArrows: .quarterTone
        case .wyschnegradsky, .sagittal: .twelfthTone
        }
    }

    /// The notation `accidental` is written in, or `nil` for a glyph none of these spell with — the standard ones,
    /// and the microtonal systems with no grid here (Arel-Ezgi-Uzdilek, Persian, Helmholtz-Ellis, …).
    public init?(writing accidental: Accidental) {
        switch accidental {
        case .mirroredFlat, .mirroredFlat2, .sharpSlash, .sharpSlash4:
            self = .steinZimmermann
        case .flatArrowUp, .flatArrowDown, .naturalArrowUp, .naturalArrowDown, .sharpArrowUp, .sharpArrowDown,
             .sharp2ArrowUp, .sharp2ArrowDown, .flat2ArrowUp, .flat2ArrowDown, .arrowUp, .arrowDown:
            self = .gouldArrows
        case .oneTwelfthFlat, .oneTwelfthSharp, .twoTwelfthFlat, .twoTwelfthSharp, .threeTwelfthFlat,
             .threeTwelfthSharp, .fourTwelfthFlat, .fourTwelfthSharp, .fiveTwelfthFlat, .fiveTwelfthSharp,
             .sixTwelfthFlat, .sixTwelfthSharp, .sevenTwelfthFlat, .sevenTwelfthSharp, .eightTwelfthFlat,
             .eightTwelfthSharp, .nineTwelfthFlat, .nineTwelfthSharp, .tenTwelfthFlat, .tenTwelfthSharp,
             .elevenTwelfthFlat, .elevenTwelfthSharp:
            self = .wyschnegradsky
        case .sagittal5v7KleismaDown, .sagittal5v7KleismaUp, .sagittal5CommaDown, .sagittal5CommaUp,
             .sagittal7CommaDown, .sagittal7CommaUp, .sagittal25SmallDiesisDown, .sagittal25SmallDiesisUp,
             .sagittal35MediumDiesisDown, .sagittal35MediumDiesisUp, .sagittal11MediumDiesisDown,
             .sagittal11MediumDiesisUp, .sagittal11LargeDiesisDown, .sagittal11LargeDiesisUp,
             .sagittal35LargeDiesisDown, .sagittal35LargeDiesisUp, .sagittalFlat25SUp, .sagittalSharp25SDown,
             .sagittalFlat7CUp, .sagittalSharp7CDown, .sagittalFlat5CUp, .sagittalSharp5CDown, .sagittalFlat5v7kUp,
             .sagittalSharp5v7kDown, .sagittalFlat, .sagittalSharp:
            self = .sagittal
        default:
            return nil
        }
    }

    /// The glyph that puts a letter `steps` grid steps from its natural, for a step taken `up` or down; `nil` when
    /// this notation has none. A whole number of semitones is never asked for — those are spelled by tpc.
    ///
    /// Gould's arrow sits on the accidental the step started from, which is why only that notation reads the
    /// direction: half a semitone above a natural is ♮↑ coming up from the natural and ♯↓ coming down from the sharp.
    func glyph(forSteps steps: Int, up: Bool) -> Accidental? {
        switch self {
        case .steinZimmermann:
            switch steps {
            case 1: .sharpSlash
            case 3: .sharpSlash4
            case -1: .mirroredFlat
            case -3: .mirroredFlat2
            default: nil
            }
        case .gouldArrows:
            switch steps {
            case 1: up ? .naturalArrowUp : .sharpArrowDown
            case 3: up ? .sharpArrowUp : .sharp2ArrowDown
            case 5: .sharp2ArrowUp
            case -1: up ? .flatArrowUp : .naturalArrowDown
            case -3: up ? .flat2ArrowUp : .flatArrowDown
            case -5: .flat2ArrowDown
            default: nil
            }
        case .wyschnegradsky:
            Self.twelfths[steps]
        case .sagittal:
            Self.sagittalTwelfths[steps]
        }
    }

    private static let twelfths: [Int: Accidental] = [
        1: .oneTwelfthSharp, 2: .twoTwelfthSharp, 3: .threeTwelfthSharp, 4: .fourTwelfthSharp,
        5: .fiveTwelfthSharp, 7: .sevenTwelfthSharp, 8: .eightTwelfthSharp, 9: .nineTwelfthSharp,
        10: .tenTwelfthSharp, 11: .elevenTwelfthSharp,
        -1: .oneTwelfthFlat, -2: .twoTwelfthFlat, -3: .threeTwelfthFlat, -4: .fourTwelfthFlat,
        -5: .fiveTwelfthFlat, -7: .sevenTwelfthFlat, -8: .eightTwelfthFlat, -9: .nineTwelfthFlat,
        -10: .tenTwelfthFlat, -11: .elevenTwelfthFlat,
    ]

    /// 72-EDO's Spartan Sagittal: the 5-comma, the 7-comma and the 11-medium-diesis, then the sharp less a 7-comma
    /// and less a 5-comma — and their flatward mirrors.
    private static let sagittalTwelfths: [Int: Accidental] = [
        1: .sagittal5CommaUp, 2: .sagittal7CommaUp, 3: .sagittal11MediumDiesisUp, 4: .sagittalSharp7CDown,
        5: .sagittalSharp5CDown,
        -1: .sagittal5CommaDown, -2: .sagittal7CommaDown, -3: .sagittal11MediumDiesisDown, -4: .sagittalFlat7CUp,
        -5: .sagittalFlat5CUp,
    ]
}

extension Note {
    /// A copy of this note one step of `notation`'s grid higher (`up`) or lower — the microtonal sibling of
    /// `shifted(bySemitones:in:)`.
    ///
    /// The step starts from where the note SOUNDS: its stored pitch plus its glyph's `centOffset`. A note whose glyph
    /// sits between this grid's points (a koron, a twelfth on the quarter-tone grid) moves to the nearest point in
    /// the step's direction.
    ///
    /// **The letter stays when it can.** A point between semitones is spelled with this notation's glyph on the
    /// note's own letter — B♭ a quarter tone up is B half-flat, not A sesquisharp — and only where the notation has
    /// no glyph that far from the letter does the step move to the next letter its way (Sagittal past five twelfths).
    /// A point ON a semitone keeps the letter while one ♯ or ♭ reaches it (A half-sharp → A♯), and is otherwise the
    /// letter's natural walked there by `shifted(bySemitones:in:)` (A sesquisharp → B), so that spelling, and the
    /// glyph shown in `keySig`, are what ↑ / ↓ would give. A glyph lands on the natural letter, as
    /// `PitchSpelling.respelled(from:with:)` stores every microtonal glyph.
    ///
    /// `nil` when the step would leave MIDI's range.
    public func shifted(oneStepOf notation: MicrotonalNotation, up: Bool, in keySig: Int = 0) -> Note? {
        let divisions = notation.step.divisionsPerSemitone
        let direction = up ? 1 : -1
        let sounding = Double(divisions * pitch) + (accidental?.centOffset ?? 0) * Double(divisions) / 100
        let nearest = sounding.rounded()
        // MuseScore rounds its twelfths to whole cents (17, 33, 67, …), so "on the grid" has to allow for that.
        let target = if abs(sounding - nearest) * 100 / Double(divisions) < 2 {
            Int(nearest) + direction
        } else {
            up ? Int(sounding.rounded(.down)) + 1 : Int(sounding.rounded(.up)) - 1
        }
        guard (0 ... 127 * divisions).contains(target) else { return nil }

        let letter = PitchSpelling.letterIndex(forTpc: tpc)
        let natural = pitch - PitchSpelling.alteration(ofTpc: tpc)
        if target.isMultiple(of: divisions) {
            return landing(
                onSemitone: target / divisions,
                letter: letter,
                natural: natural,
                direction: direction,
                keySig: keySig,
            )
        }
        for (candidateLetter, candidateNatural) in Self.letters(around: letter, natural: natural, toward: direction) {
            guard (0 ... 127).contains(candidateNatural),
                  let glyph = notation.glyph(forSteps: target - divisions * candidateNatural, up: up)
            else { continue }
            var moved = self
            moved.pitch = candidateNatural
            moved.tpc = PitchSpelling.naturalTpcByLetter[candidateLetter]
            moved.accidental = glyph
            return moved
        }
        return nil
    }

    /// A semitone the step lands on: on this letter while one ♯ / ♭ reaches it, else walked there from the letter's
    /// natural by the ↑ / ↓ rule.
    private func landing(onSemitone semitone: Int, letter: Int, natural: Int, direction: Int, keySig: Int) -> Note? {
        let alteration = semitone - natural
        guard abs(alteration) <= 1 else {
            var naturalNote = self
            naturalNote.pitch = natural
            naturalNote.tpc = PitchSpelling.naturalTpcByLetter[letter]
            naturalNote.accidental = nil
            return naturalNote.shifted(bySemitones: alteration, in: keySig)
        }
        var moved = self
        moved.pitch = semitone
        moved.tpc = PitchSpelling.naturalTpcByLetter[letter] + 7 * alteration
        moved.accidental = PitchSpelling.displayedAccidental(forTpc: moved.tpc, in: keySig)
        return moved
    }

    /// The note's own letter, then its neighbor in the step's direction, then the one behind — each with the pitch
    /// of its natural nearest the note's.
    private static func letters(around letter: Int, natural: Int, toward direction: Int) -> [(Int, Int)] {
        func neighbor(_ offset: Int) -> (Int, Int) {
            let other = ((letter + offset) % 7 + 7) % 7
            var interval = PitchSpelling.naturalSemitoneByLetter[other] - PitchSpelling.naturalSemitoneByLetter[letter]
            if offset > 0, interval < 0 { interval += 12 }
            if offset < 0, interval > 0 { interval -= 12 }
            return (other, natural + interval)
        }
        return [(letter, natural), neighbor(direction), neighbor(-direction)]
    }
}

extension PitchSpelling {
    /// How many sharps (positive) or flats (negative) `tpc` spells: 0 for a natural letter.
    static func alteration(ofTpc tpc: Int) -> Int {
        let centered = tpc - 13
        return (centered - ((centered % 7) + 7) % 7) / 7
    }
}
