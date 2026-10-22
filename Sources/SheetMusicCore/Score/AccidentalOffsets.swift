import SheetMusicFoundation

extension Accidental {
    /// Semitone shift from the natural pitch of the same diatonic letter — MuseScore's `AccidentalVal`.
    ///
    /// This is what a note STORES: applying the accidental moves the pitch by this many semitones, and the rest of
    /// the alteration rides in `centOffset`. Almost every microtonal glyph is `NATURAL` here, the three-quarter-tone
    /// flat included — it is the natural letter played 150 cents low, not a flat played 50 cents low. The one
    /// exception is Wyschnegradsky's six twelfths, which IS a semitone and carries no cents.
    ///
    /// C++: `AccidentalVal` fields in `ACC_LIST[]` (`src/engraving/dom/accidental.cpp:51-224`).
    public var semitoneOffset: Int {
        switch self {
        case .tripleFlat: -3
        case .doubleFlat: -2
        case .flat, .naturalFlat, .sixTwelfthFlat: -1
        case .natural: 0
        case .sharp, .naturalSharp, .sixTwelfthSharp: 1
        case .doubleSharp, .sharpSharp: 2
        case .tripleSharp: 3
        default: 0
        }
    }

    /// How far the glyph moves the sounding pitch from the one the note stores (`semitoneOffset` away from the
    /// natural letter), in cents. Zero for every standard accidental.
    ///
    /// The values are MuseScore's, verbatim — so a score sounds in folino the way it sounds in MuseScore. That
    /// includes MuseScore's zeros: the Extended Helmholtz-Ellis arrows and commas, the equal-tempered set and the
    /// enharmonic marks carry no offset there, so they play their stored pitch here too.
    ///
    /// C++: `Acc::centOffset` in `ACC_LIST[]` (`src/engraving/dom/accidental.cpp:51-224`), read by
    /// `Accidental::subtype2centOffset` and played as a pitch-wheel offset by `CompatMidiRender`'s `playNote`.
    public var centOffset: Double {
        switch self {
        // Gould arrow quartertone
        case .flatArrowUp, .naturalArrowDown, .arrowDown: -50
        case .flatArrowDown, .flat2ArrowUp: -150
        case .naturalArrowUp, .sharpArrowDown, .arrowUp: 50
        case .sharpArrowUp, .sharp2ArrowDown: 150
        case .sharp2ArrowUp: 250
        case .flat2ArrowDown: -250
        // Stein-Zimmermann
        case .mirroredFlat: -50
        case .mirroredFlat2: -150
        case .sharpSlash: 50
        case .sharpSlash4: 150
        // Arel-Ezgi-Uzdilek
        case .flatSlash2: -89
        case .flatSlash: -44
        case .sharpSlash3: 56
        case .sharpSlash2: 89
        // Helmholtz-Ellis schisma and comma combining marks
        case .flat17: -6.8
        case .sharp17: 6.8
        case .flat19: -3.4
        case .sharp19: 3.4
        case .flat23: -16.5
        case .sharp23: 16.5
        case .flat31: -1.7
        case .sharp31: 1.7
        case .flat53: -10.9
        case .sharp53: 10.9
        // Persian
        case .sori: 33
        case .koron: -67
        // Wyschnegradsky (six twelfths is a plain semitone — `semitoneOffset`)
        case .oneTwelfthFlat: -17
        case .oneTwelfthSharp: 17
        case .twoTwelfthFlat: -33
        case .twoTwelfthSharp: 33
        case .threeTwelfthFlat: -50
        case .threeTwelfthSharp: 50
        case .fourTwelfthFlat: -67
        case .fourTwelfthSharp: 67
        case .fiveTwelfthFlat: -83
        case .fiveTwelfthSharp: 83
        case .sevenTwelfthFlat: -117
        case .sevenTwelfthSharp: 117
        case .eightTwelfthFlat: -133
        case .eightTwelfthSharp: 133
        case .nineTwelfthFlat: -150
        case .nineTwelfthSharp: 150
        case .tenTwelfthFlat: -167
        case .tenTwelfthSharp: 167
        case .elevenTwelfthFlat: -183
        case .elevenTwelfthSharp: 183
        // Sagittal (Spartan)
        case .sagittal5v7KleismaDown, .sagittal5CommaDown: -17
        case .sagittal5v7KleismaUp, .sagittal5CommaUp: 17
        case .sagittal7CommaDown, .sagittal25SmallDiesisDown: -33
        case .sagittal7CommaUp, .sagittal25SmallDiesisUp: 33
        case .sagittal35MediumDiesisDown, .sagittal11MediumDiesisDown, .sagittal11LargeDiesisDown,
             .sagittal35LargeDiesisDown: -50
        case .sagittal35MediumDiesisUp, .sagittal11MediumDiesisUp, .sagittal11LargeDiesisUp,
             .sagittal35LargeDiesisUp: 50
        case .sagittalFlat25SUp, .sagittalFlat7CUp: -67
        case .sagittalSharp25SDown, .sagittalSharp7CDown: 67
        case .sagittalFlat5CUp, .sagittalFlat5v7kUp: -83
        case .sagittalSharp5CDown, .sagittalSharp5v7kDown: 83
        case .sagittalFlat: -100
        case .sagittalSharp: 100
        // Turkish folk music
        case .oneCommaFlat: -22.2
        case .oneCommaSharp: 22.2
        case .twoCommaFlat: -44.4
        case .twoCommaSharp: 44.4
        case .threeCommaFlat: -66.7
        case .threeCommaSharp: 66.7
        case .fourCommaFlat: -88.9
        case .fiveCommaSharp: 111.1
        default: 0
        }
    }
}
