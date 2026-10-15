#if os(macOS)
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicMSCX
    import Testing

    /// Writes this library's save of the dynamics fixture after two palette edits — bar 2's "subito p" changed to `f`
    /// (its words must go) and bar 1's `p` given "subito ⟨p⟩" as xml text, as a paste writes it — to
    /// `SM_W4_RESAVE_OUT/dynamics-ssm.mscx`, for MuseScore to open (import fidelity W4, Task 15). Gated: a before/after
    /// tool, nothing committed reads its output.
    @Suite(.enabled(if: ProcessInfo.processInfo.environment["SM_W4_RESAVE_OUT"] != nil))
    struct DynamicMuseScoreResaveTests {
        @Test("write the saved dynamics fixture")
        func write() throws {
            let directory = try #require(ProcessInfo.processInfo.environment["SM_W4_RESAVE_OUT"])
            var score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("dynamics"))
            let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
            // Bar 1 is [time signature, p, C × 4]; bar 2 is ["subito p", C × 4].
            let barOneChord = VoiceElementID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 2)
            let barTwoChord = VoiceElementID(staff: staff, measureIndex: 1, voiceIndex: 0, elementIndex: 1)
            _ = try SetDynamic(at: barTwoChord, subtype: "f").apply(to: &score)
            _ = try SetDynamic(at: barOneChord, subtype: "p", xmlText: "subito <sym>dynamicPiano</sym>")
                .apply(to: &score)
            let url = URL(fileURLWithPath: directory).appendingPathComponent("dynamics-ssm.mscx")
            try MSCXEncoder.encode(score).write(to: url)
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }
#endif
