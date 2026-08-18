@testable import SheetMusicBridgeCore
import SheetMusicCore
import SheetMusicFoundation
import SheetMusicMSCX
@testable import SheetMusicWasmBridge
import Testing

/// The mixer surface, and the reason it has to exist.
///
/// `renderMidi` strips the tick-0 program and CC 7 from every mixer-managed
/// channel so a backward seek cannot replay them over a live override. That
/// makes the host responsible for asserting both — and a host that does not
/// hears every melodic part as Acoustic Grand Piano, which is a General MIDI
/// channel's default. Percussion masks it: channel 9 picks the drum bank
/// whatever the program is.
@Suite("mixer strips")
struct MixerStripTests {
    /// Two melodic parts on different patches plus a drum part — the shape that
    /// exposes the bug. A single-piano fixture cannot: program 0 is both what
    /// the score asks for and what a stripped channel falls back to.
    private static func mixedScore() -> Score {
        func part(
            id: String, name: String, program: Int, drums: Bool, volume: Int,
        ) -> Part {
            let elements: [VoiceElement] = [60, 62, 64, 65].map { pitch in
                .chord(Chord(duration: .quarter, notes: ChordNotes([Note(pitch: pitch, tpc: 14)])))
            }
            return Part(
                id: id,
                instrument: Instrument(
                    id: id,
                    longName: name,
                    channels: [InstrumentChannel(program: program, volume: volume)],
                    useDrumset: drums,
                ),
                staves: [Staff(measures: [Measure(voices: [Voice(elements: elements)])])],
            )
        }
        return Score(
            division: 480,
            parts: [
                part(id: "bass", name: "Bass", program: 33, drums: false, volume: 92),
                part(id: "lead", name: "Lead", program: 84, drums: false, volume: 64),
                part(id: "drums", name: "Drums", program: 0, drums: true, volume: 100),
            ],
            metaTags: ["workTitle": "mixer"],
        )
    }

    private static func mscz() throws -> [UInt8] {
        try [UInt8](MSCZWriter.write(score: mixedScore()))
    }

    @Test("every part gets a strip")
    func stripPerPart() throws {
        let handle = try loadScore(bytes: Self.mscz())
        defer { releaseScore(handle: handle) }
        #expect(mixerStripCount(handle: handle) == 3)
    }

    @Test("an unknown handle has no strips")
    func unknownHandleHasNoStrips() {
        #expect(mixerStripCount(handle: 999_999) == 0)
        #expect(mixerStrip(handle: 999_999, index: 0) == nil)
    }

    @Test("an out-of-range index is nil")
    func outOfRangeIndexIsNil() throws {
        let handle = try loadScore(bytes: Self.mscz())
        defer { releaseScore(handle: handle) }
        #expect(mixerStrip(handle: handle, index: -1) == nil)
        #expect(mixerStrip(handle: handle, index: 3) == nil)
    }

    /// The regression this suite exists for: the strips have to carry the
    /// score's own patches, because the sequence no longer does.
    @Test("the strips carry the score's programs and volumes")
    func stripsCarryProgramsAndVolumes() throws {
        let handle = try loadScore(bytes: Self.mscz())
        defer { releaseScore(handle: handle) }
        var strips: [MixerStrip] = []
        for index in 0 ..< mixerStripCount(handle: handle) {
            try strips.append(#require(mixerStrip(handle: handle, index: index)))
        }
        #expect(strips.map(\.program) == [33, 84, 0])
        #expect(strips.map(\.volume) == [92, 64, 100])
        #expect(strips.map(\.isDrums) == [false, false, true])
        #expect(strips.map(\.displayName) == ["Bass", "Lead", "Drums"])
    }

    /// Each strip has to name the channel the RENDERED sequence uses, not the
    /// part's index — the drum part is on channel 9 whatever its position.
    @Test("each strip names the channel its part actually sounds on")
    func stripsNameTheLiveChannel() throws {
        let handle = try loadScore(bytes: Self.mscz())
        defer { releaseScore(handle: handle) }
        var strips: [MixerStrip] = []
        for index in 0 ..< mixerStripCount(handle: handle) {
            try strips.append(#require(mixerStrip(handle: handle, index: index)))
        }
        #expect(Set(strips.map(\.channel)).count == strips.count)
        let drumChannels = strips.filter(\.isDrums).map(\.channel)
        #expect(drumChannels == [9])
    }

    /// Pins the premise. If the renderer ever stopped stripping, the host would
    /// be asserting programs on top of a sequence that already sets them, and a
    /// backward seek would start fighting the mixer.
    @Test("the rendered sequence carries no program change of its own")
    func renderedSequenceHasNoProgramChanges() throws {
        let handle = try loadScore(bytes: Self.mscz())
        defer { releaseScore(handle: handle) }
        let bytes = renderMidi(handle: handle)
        #expect(!bytes.isEmpty)
        // Program change is status 0xC0 | channel. Scanning raw SMF bytes is
        // crude — a data byte can collide — but a sequence that DID carry six
        // of them could not read as zero, which is the direction that matters.
        let programStatuses = Set<UInt8>((0xC0 ... 0xCF).map { UInt8($0) })
        #expect(!bytes.contains { programStatuses.contains($0) })
    }
}
