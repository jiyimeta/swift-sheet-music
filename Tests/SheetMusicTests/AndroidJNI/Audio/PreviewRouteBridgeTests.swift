#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicAndroidJNI
    @testable import SheetMusicAudioCore
    @testable import SheetMusicBridgeCore
    import SheetMusicCore
    import SheetMusicEditWire
    import SheetMusicFoundation
    import Testing

    /// The Android engine routes a note audition through `nativePreviewRoute`, the rule the Apple and Windows engines
    /// apply (`PreviewRouting`): the channel the note's staff plays at the note's tick, after any instrument change.
    @Suite("preview route bridge")
    struct PreviewRouteBridgeTests {
        /// Two 4/4 measures of quarter notes (pitch 60) on one piano staff; measure 0 opens with its time signature, so
        /// its first chord is element 1 and measure 1's first is element 0.
        private static func score() -> Score {
            let measures = (0 ..< 2).map { index in
                let timeSignature: [VoiceElement] = index == 0
                    ? [.timeSignature(TimeSignature(numerator: 4, denominator: 4))]
                    : []
                let quarter = Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])
                return Measure(voices: [Voice(elements: timeSignature + Array(repeating: .chord(quarter), count: 4))])
            }
            return Score(
                division: 480,
                parts: [
                    Part(
                        id: "piano",
                        instrument: Instrument(
                            id: "piano", longName: "Piano", channels: [InstrumentChannel(program: 0)],
                        ),
                        staves: [Staff(measures: measures)],
                    ),
                ],
                systemMeasures: IdentifiedArray(Array(repeating: SystemMeasure(), count: 2)),
            )
        }

        /// [score] with the piano changing to an accordion at the head of measure 1.
        private static func scoreWithInstrumentChange() -> Score {
            let accordion = Instrument(
                id: "accordion", longName: "Accordion", channels: [InstrumentChannel(program: 21)],
            )
            var score = score()
            score.systemMeasures.updateValue(at: 1) { systemMeasure in
                systemMeasure.elements = [
                    PositionedSystemElement(
                        position: MeasurePosition(offset: Fraction(numerator: 0, denominator: 1)),
                        element: .instrumentChange(InstrumentChange(text: "Accordion", instrument: accordion)),
                        originalStaff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
                    ),
                ]
            }
            return score
        }

        private static func noteID(measure: Int, element: Int) -> NoteID {
            NoteID(
                staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
                measureIndex: measure, voiceIndex: 0, elementIndex: element, noteIndexInChord: 0,
            )
        }

        /// The opening (piano) and changed (accordion) live channels of `score`'s only part.
        private static func channels(of score: Score) throws -> (opening: Int, changed: Int) {
            let plan = PlaybackChannelLayout(score: score).liveChannelPlan
            let opening = try #require(plan.strip(partIndex: 0, ordinal: 0)).liveChannel
            let changed = try #require(plan.strip(partIndex: 0, ordinal: 1)).liveChannel
            return (opening, changed)
        }

        @Test("a note after an instrument change sounds on the changed instrument's channel")
        func noteAfterChangeRoutesToChangedChannel() throws {
            let score = Self.scoreWithInstrumentChange()
            let (opening, changed) = try Self.channels(of: score)
            #expect(opening != changed)

            let before = AudioMidiBridge.previewRoute(
                score: score, prepared: score, noteID: Self.noteID(measure: 0, element: 4), pitch: nil,
            )
            let after = AudioMidiBridge.previewRoute(
                score: score, prepared: score, noteID: Self.noteID(measure: 1, element: 0), pitch: nil,
            )

            #expect(before == .init(pitch: 60, staffIndex: 0, channel: opening, isDrum: false))
            #expect(after == .init(pitch: 60, staffIndex: 0, channel: changed, isDrum: false))
        }

        @Test("a pitch in the note's place sounds on the note's channel")
        func pitchOverrideKeepsTheNotesChannel() throws {
            let score = Self.scoreWithInstrumentChange()
            let (_, changed) = try Self.channels(of: score)

            let route = AudioMidiBridge.previewRoute(
                score: score, prepared: score, noteID: Self.noteID(measure: 1, element: 0), pitch: 74,
            )

            #expect(route == .init(pitch: 74, staffIndex: 0, channel: changed, isDrum: false))
        }

        @Test("the instrument changes are the prepared score's, so one the edit added waits for its adoption")
        func routesThroughThePreparedScore() throws {
            let prepared = Self.score()
            let edited = Self.scoreWithInstrumentChange()
            let opening = try #require(PlaybackChannelLayout(score: prepared).staffMIDIChannels[0])

            let route = AudioMidiBridge.previewRoute(
                score: edited, prepared: prepared, noteID: Self.noteID(measure: 1, element: 0), pitch: nil,
            )

            #expect(route?.channel == Int(opening))
        }

        @Test("a note that does not resolve has no route")
        func unresolvedNoteHasNoRoute() {
            let score = Self.score()
            #expect(AudioMidiBridge.previewRoute(
                score: score, prepared: score, noteID: Self.noteID(measure: 7, element: 0), pitch: nil,
            ) == nil)
        }

        @Test("the JNI entry answers [pitch, staff, channel, drum], and routes through the score when there is no copy")
        func nativeEntryWire() throws {
            let score = Self.scoreWithInstrumentChange()
            let (_, changed) = try Self.channels(of: score)
            let handle = scoreTable.insert(score)
            defer { nativeReleaseScore(handle: handle) }
            let noteBytes = PathIDCodecs.encode(Self.noteID(measure: 1, element: 0))

            let own = nativePreviewRoute(
                scoreHandle: handle, preparedScoreHandle: 0, noteIdBytes: noteBytes, pitch: -1,
            )
            let overridden = nativePreviewRoute(
                scoreHandle: handle, preparedScoreHandle: handle, noteIdBytes: noteBytes, pitch: 74,
            )

            #expect(own == [60, 0, Int64(changed), 0])
            #expect(overridden == [74, 0, Int64(changed), 0])
            #expect(nativePreviewRoute(
                scoreHandle: -42, preparedScoreHandle: 0, noteIdBytes: noteBytes, pitch: -1,
            ).isEmpty)
        }
    }
#endif
