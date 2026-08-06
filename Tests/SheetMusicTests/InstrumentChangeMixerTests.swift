#if !os(Android)
    import Foundation
    @testable import SheetMusicAndroidJNI
    @testable import SheetMusicAudioApple
    @testable import SheetMusicAudioCore
    @testable import SheetMusicCore
    @testable import SheetMusicMIDI
    @testable import SheetMusicMSCX
    import Testing

    @Suite("InstrumentChange mixer")
    struct InstrumentChangeMixerTests {
        static func fixtureScore() throws -> Score {
            let url = try #require(
                Bundle.module.url(
                    forResource: "instrument-change", withExtension: "mscx",
                ),
            )
            return try MSCXParser.parse(Data(contentsOf: url))
        }

        @Test("one strip per (part × distinct instrument)")
        func stripPerInstrument() throws {
            let plan = try LiveChannelPlan.build(score: Self.fixtureScore())
            #expect(plan.strips.map { ($0.partIndex, $0.ordinal) }.count == 2)
            #expect(plan.strips[0].instrument.id == "piano")
            #expect(plan.strips[1].instrument.id == "accordion")
        }

        @Test("a grand-staff part shows ONE strip, not one per staff")
        func grandStaffCollapses() {
            let bar = Measure(voices: [Voice(elements: [])])
            let score = Score(
                division: 480,
                parts: [Part(
                    id: "P1",
                    instrument: Instrument(id: "piano", channels: [InstrumentChannel()]),
                    staves: [Staff(measures: [bar]), Staff(measures: [bar])],
                )],
                systemMeasures: [SystemMeasure()],
            )
            // Today `staffChannels` hands every staff of a part the same
            // channel, so a grand staff shows two strips driving one
            // channel. Per-(part × instrument) strips remove the duplicate.
            #expect(LiveChannelPlan.build(score: score).strips.count == 1)
        }

        @Test("Kind is Hashable and distinguishes ordinals")
        func kindIdentity() {
            let a = MixerChannel.Kind.instrument(partIndex: 0, ordinal: 0)
            let b = MixerChannel.Kind.instrument(partIndex: 0, ordinal: 1)
            let c = MixerChannel.Kind.instrument(partIndex: 1, ordinal: 0)
            #expect(Set([a, b, c, .metronome]).count == 4)
        }

        @Test("program re-assertion covers every deduped instrument channel")
        func managedChannelsCoverSecondaries() throws {
            let plan = try LiveChannelPlan.build(score: Self.fixtureScore())
            // With all programs living at tick 0, re-asserting only the
            // primary staff channel would leave the accordion playing
            // program 0 piano. The count check alone doesn't prove
            // anything is DISTINCT — two strips could both (wrongly)
            // report the same live channel and still pass a bare count
            // assertion, so also require the two channels differ.
            #expect(plan.managedChannels.count == 2)
            let channels = plan.strips.map(\.liveChannel)
            #expect(Set(channels).count == channels.count)
        }

        @Test("instrument params expose one entry per deduped strip")
        func instrumentParamsPerStrip() throws {
            let score = try Self.fixtureScore()
            let data = AudioMidiBridge.instrumentParams(score: score)
            let params = try InstrumentParamsCodec.decodeArray(data)
            #expect(params.count == 2)
            #expect(params[0].partIndex == 0 && params[0].ordinal == 0)
            #expect(params[0].program == 0)
            #expect(params[1].partIndex == 0 && params[1].ordinal == 1)
            #expect(params[1].program == 21)
            #expect(params[1].liveChannel != params[0].liveChannel)
            #expect(params[1].displayName.contains("Accordion"))
        }

        @Test("instrument params round-trip through the codec")
        func codecRoundTrip() throws {
            let original = [InstrumentParams(
                partIndex: 1, ordinal: 2, liveChannel: 5,
                bankLSB: 0, program: 21, isDrums: false,
                displayName: "S (Accordion)", channelVolume: 100,
            )]
            let decoded = try InstrumentParamsCodec.decodeArray(
                InstrumentParamsCodec.encodeArray(original),
            )
            #expect(decoded == original)
        }

        /// Regression guard for the Kotlin decoder: pins the exact bytes
        /// `InstrumentParamsCodec.encodeArray` produces for the fixture
        /// score, committed at
        /// `Tests/SheetMusicTests/Resources/Golden/Audio/instrumentParams-v1.bin`
        /// and mirrored by a Kotlin decode test
        /// (`InstrumentParamsCodecTest.kt`) asserting the SAME fixture
        /// bytes decode to the SAME field values on both platforms. This
        /// is the regression guard the spec asked for — see "Deviations"
        /// in the Task 12 report for why it lands here instead of on a
        /// TextStyle enum field (there is none).
        @Test("instrument params golden bytes match the committed fixture")
        func instrumentParamsGoldenMatches() throws {
            let score = try Self.fixtureScore()
            let encoded = AudioMidiBridge.instrumentParams(score: score)
            let goldenDir = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent() // SheetMusicTests
                .appendingPathComponent("Resources/Golden/Audio")
            let committed = try Data(
                contentsOf: goldenDir.appendingPathComponent("instrumentParams-v1.bin"),
            )
            #expect(encoded == committed)
        }
    }

    /// Engine-level companion to `InstrumentChangeMixerTests` above:
    /// those tests only exercise `LiveChannelPlan` in isolation and never
    /// construct a `PlaybackEngine`, so nothing there proves the SECOND
    /// instrument's program actually reaches the synth — only that the
    /// plan SAYS it should. This suite drives a real (double-backed)
    /// engine through `prepare` + `play` and asserts on what the backend
    /// received.
    extension AudioEngineSerial {
        @Suite("InstrumentChange mixer — engine")
        @MainActor
        struct InstrumentChangeMixerEngineTests {
            private struct NullResolver: SoundfontResolver {
                func soundfontURL(forBank _: UInt8, program _: UInt8, isDrums _: Bool) -> URL? {
                    nil
                }

                var defaultGMSoundfontURL: URL? {
                    nil
                }
            }

            /// The bug this task exists to prevent: a part with a mid-score
            /// instrument change gets ONE strip per instrument, and each
            /// strip's program must reach its OWN live channel — not just
            /// the part's tick-0 (ordinal-0) channel. Looks the accordion's
            /// live channel and program up from the `LiveChannelPlan`
            /// itself (never hardcoded), so this survives a change in
            /// channel-allocation order.
            @Test("the accordion's program reaches ITS OWN live channel, not the piano's")
            func secondaryInstrumentProgramReachesItsOwnChannel() throws {
                let score = try InstrumentChangeMixerTests.fixtureScore()
                let plan = LiveChannelPlan.build(score: score)
                let piano = try #require(plan.strips.first { $0.instrument.id == "piano" })
                let accordion = try #require(plan.strips.first { $0.instrument.id == "accordion" })
                // Sanity on the fixture itself: this must be the SECONDARY
                // instrument (ordinal 1), and its live channel must differ
                // from the primary's — otherwise the assertion below would
                // pass for the wrong reason.
                #expect(accordion.ordinal == 1)
                #expect(accordion.liveChannel != piano.liveChannel)

                let backend = RecordingBackend()
                let engine = PlaybackEngine(soundfontResolver: NullResolver(), backend: backend)
                try engine.prepare(score: score)
                engine.play(in: score)

                let accordionChannel = UInt8(clamping: accordion.liveChannel)
                let accordionProgram = UInt8(clamping: accordion.instrument.channel.program)
                #expect(backend.programSends.contains {
                    $0.channel == accordionChannel && $0.program == accordionProgram
                })
            }
        }
    }

    /// Strip-naming rules — `PlaybackEngine+Mixer.stripName`. Driven
    /// through `rebuildMixerChannels(for:)` (the only entry point;
    /// `stripName` itself is `private`), which is a pure data
    /// transform with no audio-engine side effect, but every test that
    /// constructs a `PlaybackEngine` is nested under `AudioEngineSerial`
    /// per repo convention.
    extension AudioEngineSerial {
        @Suite("InstrumentChange mixer — strip naming")
        @MainActor
        struct InstrumentChangeMixerStripNamingTests {
            private struct NullResolver: SoundfontResolver {
                func soundfontURL(forBank _: UInt8, program _: UInt8, isDrums _: Bool) -> URL? {
                    nil
                }

                var defaultGMSoundfontURL: URL? {
                    nil
                }
            }

            private func stripNames(for score: Score) -> [String] {
                let engine = PlaybackEngine(soundfontResolver: NullResolver())
                engine.rebuildMixerChannels(for: score)
                return engine.mixerChannels.compactMap { channel in
                    guard case .instrument = channel.id else { return nil }
                    return channel.name
                }
            }

            /// One part, one instrument-change point whose instrument
            /// genuinely differs from the part's own — the suffix must
            /// appear, and the primary strip must stay bare (it always
            /// equals the part label by construction).
            @Test("suffix appears for a genuine second instrument")
            func suffixAppearsForGenuineSecondInstrument() throws {
                let names = try stripNames(for: InstrumentChangeMixerTests.fixtureScore())
                #expect(names == ["Piano", "Piano (Accordion)"])
            }

            /// The exact regression this finding reported: `instrument-change.mscx`'s
            /// PRIMARY strip's own instrument long name ("Piano") equals the
            /// part label ("Piano", also derived from the tick-0 instrument's
            /// long name) — the parenthesised suffix must be suppressed
            /// rather than rendering "Piano (Piano)".
            @Test("suppressed when the instrument name would duplicate the part label")
            func suppressedWhenDuplicatesPartLabel() throws {
                let names = try stripNames(for: InstrumentChangeMixerTests.fixtureScore())
                #expect(!names.contains("Piano (Piano)"))
                #expect(names.first == "Piano")
            }

            /// No instrument change at all — a single strip, and no
            /// parenthesised suffix regardless of instrument naming.
            @Test("absent for a single-instrument part")
            func absentForSingleInstrumentPart() {
                let score = Score(
                    division: 480,
                    parts: [Part(
                        id: "P1",
                        instrument: Instrument(
                            id: "cello", longName: "Cello",
                            channels: [InstrumentChannel(program: 42)],
                        ),
                        staves: [Staff(measures: [Measure(voices: [])])],
                    )],
                )
                #expect(stripNames(for: score) == ["Cello"])
            }

            /// A part whose two timeline entries dedup onto ONE live
            /// channel (identical `InstrumentChannel` flavour — see
            /// `LiveChannelPlan`'s dedup rule) must NOT show a suffix:
            /// gating on `score.instrumentTimeline(forPart:).count` (2
            /// here) rather than the DEDUPED strip count (1 here) was
            /// exactly this finding's bug.
            @Test("absent when the timeline has two entries but they dedup to one strip")
            func absentWhenTimelineDedupsToOneStrip() {
                let flavour = InstrumentChannel(program: 68)
                let tick0 = Instrument(id: "oboe", longName: "Oboe", channels: [flavour])
                // Different Instrument OBJECT (own id / longName), but the
                // SAME sounding channel flavour as tick0 — collapses onto
                // the same live channel per `LiveChannelPlan.build`.
                let sameFlavourChange = Instrument(id: "flute-alias", longName: "Flute", channels: [flavour])
                let score = Score(
                    division: 480,
                    parts: [Part(
                        id: "P1", instrument: tick0,
                        staves: [Staff(measures: [Measure(voices: [])])],
                    )],
                    systemMeasures: [SystemMeasure(elements: [
                        PositionedSystemElement(
                            position: MeasurePosition(numerator: 1, denominator: 4),
                            element: .instrumentChange(InstrumentChange(
                                text: "→", instrument: sameFlavourChange,
                            )),
                            originalStaff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
                        ),
                    ])],
                )
                // Confirm the premise: two timeline entries, one strip.
                #expect(score.instrumentTimeline(forPart: 0).count == 2)
                #expect(LiveChannelPlan.build(score: score).strips.count == 1)
                #expect(stripNames(for: score) == ["Oboe"])
            }

            /// Instrument-name fallback order: longName → trackName → id.
            /// Exercised on SECONDARY strips (ordinal ≥ 1), because the
            /// PRIMARY strip's name is always suppressed to the bare part
            /// label (see `suppressedWhenDuplicatesPartLabel`) and so can
            /// never show its own fallback tier.
            @Test("instrument-name fallback order is longName → trackName → id")
            func fallbackOrder() {
                let tick0 = Instrument(
                    id: "p0", longName: "Guitar", channels: [InstrumentChannel(program: 0)],
                )
                let viaLongName = Instrument(
                    id: "inst-a", longName: "Banjo", trackName: "ignored-a",
                    channels: [InstrumentChannel(program: 10)],
                )
                let viaTrackName = Instrument(
                    id: "inst-b", trackName: "Mandolin",
                    channels: [InstrumentChannel(program: 20)],
                )
                let viaID = Instrument(
                    id: "inst-c",
                    channels: [InstrumentChannel(program: 30)],
                )
                func change(at beat: Int, _ instrument: Instrument) -> PositionedSystemElement {
                    PositionedSystemElement(
                        position: MeasurePosition(numerator: beat, denominator: 4),
                        element: .instrumentChange(InstrumentChange(text: "→", instrument: instrument)),
                        originalStaff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
                    )
                }
                let score = Score(
                    division: 480,
                    parts: [Part(
                        id: "P1", instrument: tick0,
                        staves: [Staff(measures: [Measure(voices: [])])],
                    )],
                    systemMeasures: [SystemMeasure(elements: [
                        change(at: 1, viaLongName),
                        change(at: 2, viaTrackName),
                        change(at: 3, viaID),
                    ])],
                )
                #expect(stripNames(for: score) == [
                    "Guitar", "Guitar (Banjo)", "Guitar (Mandolin)", "Guitar (inst-c)",
                ])
            }
        }
    }
#endif
