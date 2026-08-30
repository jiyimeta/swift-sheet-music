@testable import SheetMusicCore
import Testing

@Suite("GMDrumset")
struct GMDrumsetTests {
    /// The line map as it stood when it was the only half of the table that was public. Written out literally
    /// rather than read from `GMPercussion`, so this test still fails if both sides are edited together — a drum
    /// that moves line silently re-engraves every existing drum score.
    private static let historicalLineMap: [Int: Int] = [
        35: 6, 36: 6, 37: 2, 38: 2, 39: 2, 40: 2, 41: 8, 42: -1, 43: 7, 44: 9,
        45: 5, 46: -1, 47: 4, 48: 3, 49: -1, 50: 2, 51: 0, 52: -1, 53: 0, 54: 0,
        55: -1, 56: 0, 57: -1, 58: 1, 59: 0, 60: 1, 61: 2,
    ]

    @Test("the table covers exactly the pitches the old private tables did")
    func coverage() {
        #expect(Set(GMDrumset.entries.keys) == Set(35 ... 61))
    }

    @Test("GMPercussion.drumLineMap is the table's lines, unchanged")
    func lineMapUnchanged() {
        #expect(GMPercussion.drumLineMap == Self.historicalLineMap)
        #expect(GMDrumset.entries.mapValues(\.line) == Self.historicalLineMap)
    }

    @Test("cymbals and hi-hats carry the cross head, the side stick and electric snare their own")
    func heads() {
        let cross: Set = [42, 44, 46, 49, 51, 52, 53, 54, 55, 57, 59]
        for (pitch, entry) in GMDrumset.entries {
            switch pitch {
            case 37: #expect(entry.head == "slashed1")
            case 40: #expect(entry.head == "slash")
            case _ where cross.contains(pitch): #expect(entry.head == "cross")
            default: #expect(entry.head == "normal")
            }
        }
    }

    @Test("the feet voice is bass drum, pedal hi-hat and low floor tom, stems down")
    func voicesAndStems() {
        for (pitch, entry) in GMDrumset.entries {
            let isFeet = [35, 36, 41, 44].contains(pitch)
            #expect(entry.voiceIndex == (isFeet ? 1 : 0))
            #expect(entry.stem == (isFeet ? 2 : 1))
        }
    }

    @Test("every entry is named — MuseScore drops a nameless <Drum>")
    func names() {
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
