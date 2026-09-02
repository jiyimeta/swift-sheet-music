@testable import SheetMusicCore
import Testing

@Suite("GMDrumset")
struct GMDrumsetTests {
    /// MuseScore Studio's stock drumset, transcribed by hand from `share/instruments/instruments.xml`'s
    /// `<Instrument id="drumset">` — the block a Drumset part is actually built from — plus `smDrumset`
    /// (`src/engraving/dom/drumset.cpp`) for the four pitches that block omits: 39, 58, 60 and 61.
    ///
    /// Written out literally rather than read back from `GMDrumset`, so editing both sides together still fails.
    /// The claim under test is that a drum score authored here and one authored in MuseScore put the same
    /// instrument on the same line, and nothing derived from the table itself can check that.
    ///
    /// 52 is the one entry that is not a literal transcription: `instruments.xml` gives it a normal head plus a
    /// per-duration `<noteheads>` override to `noteheadHeavyXHat`, which a single head token cannot express, so
    /// the equivalent `heavy-cross-hat` group stands in for it.
    private static let museScoreDrumset: [Int: (head: String, line: Int, voice: Int, stem: Int)] = [
        35: ("normal", 8, 1, 2),
        36: ("normal", 7, 1, 2),
        37: ("slashed1", 3, 0, 1),
        38: ("normal", 3, 0, 1),
        39: ("plus", -2, 0, 1),
        40: ("slash", 3, 0, 1),
        41: ("normal", 6, 0, 1),
        42: ("cross", -1, 0, 1),
        43: ("normal", 5, 0, 1),
        44: ("cross", 9, 1, 2),
        45: ("normal", 4, 0, 1),
        46: ("xcircle", -1, 0, 1),
        47: ("normal", 2, 0, 1),
        48: ("normal", 1, 0, 1),
        49: ("cross", -2, 0, 1),
        50: ("normal", 0, 0, 1),
        51: ("cross", 0, 0, 1),
        52: ("heavy-cross-hat", -3, 0, 1),
        53: ("diamond", 0, 0, 1),
        54: ("diamond", 1, 0, 1),
        55: ("cross", -4, 0, 1),
        56: ("triangle-down", 1, 0, 1),
        57: ("cross", -3, 0, 1),
        58: ("ti", 0, 0, 1),
        59: ("cross", 2, 0, 1),
        60: ("normal", -1, 0, 1),
        61: ("normal", 0, 0, 1),
    ]

    @Test("the table covers exactly the pitches the old private tables did")
    func coverage() {
        #expect(Set(GMDrumset.entries.keys) == Set(35 ... 61))
    }

    @Test("every drum is engraved where MuseScore engraves it")
    func matchesMuseScore() {
        for (pitch, expected) in Self.museScoreDrumset {
            guard let entry = GMDrumset.entries[pitch] else {
                Issue.record("pitch \(pitch) is missing from the table"); continue
            }
            #expect(entry.line == expected.line, "line for pitch \(pitch)")
            #expect(entry.head == expected.head, "head for pitch \(pitch)")
            #expect(entry.voiceIndex == expected.voice, "voice for pitch \(pitch)")
            #expect(entry.stem == expected.stem, "stem for pitch \(pitch)")
        }
    }

    @Test("GMPercussion.drumLineMap is the table's lines, unchanged")
    func lineMapIsTheTablesLines() {
        #expect(GMPercussion.drumLineMap == GMDrumset.entries.mapValues(\.line))
        #expect(GMPercussion.drumLineMap == Self.museScoreDrumset.mapValues(\.line))
    }

    /// The two bass drums and the pedal hi-hat, and nothing else. The low floor tom is played by hand and is
    /// voice 0 in MuseScore — a stems-down floor tom was this table's own invention.
    @Test("the feet voice is the bass drums and the pedal hi-hat, stems down")
    func voicesAndStems() {
        for (pitch, entry) in GMDrumset.entries {
            let isFeet = [35, 36, 44].contains(pitch)
            #expect(entry.voiceIndex == (isFeet ? 1 : 0))
            #expect(entry.stem == (isFeet ? 2 : 1))
        }
    }

    @Test("every entry is named — MuseScore drops a nameless <Drum>")
    func names() {
        #expect(GMDrumset.entries[35]?.name == "Bass Drum 2")
        #expect(GMDrumset.entries[36]?.name == "Bass Drum 1")
        #expect(GMDrumset.entries[38]?.name == "Acoustic Snare")
        #expect(GMDrumset.entries[42]?.name == "Closed Hi-Hat")
        for entry in GMDrumset.entries.values {
            #expect(!entry.name.isEmpty)
        }
    }

    @Test("a pitch the table does not know still gets a writable entry on the line it is asked for")
    func fallback() {
        let entry = GMDrumset.entry(forPitch: 63, line: 4)
        #expect(entry.line == 4)
        #expect(entry.name == "Drum 63")
        #expect(entry.head == "normal")
        #expect(entry.voiceIndex == 0)
        #expect(entry.stem == 1)
        #expect(entry.shortcut == nil)
    }

    @Test("a known pitch asked for a different line keeps its name, head and voice")
    func knownPitchWithOverriddenLine() {
        let entry = GMDrumset.entry(forPitch: 42, line: 3)
        #expect(entry.line == 3)
        #expect(entry.head == "cross")
        #expect(entry.name == "Closed Hi-Hat")
    }
}
