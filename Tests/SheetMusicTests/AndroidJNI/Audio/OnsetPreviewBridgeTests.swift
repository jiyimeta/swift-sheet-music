#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicAndroidJNI
    @testable import SheetMusicAudioCore
    @testable import SheetMusicBridgeCore
    import SheetMusicCore
    import SheetMusicEditWire
    import Testing

    /// The Android engine sounds a tap the way the Apple hosts do: every note starting on the tapped beat, struck as
    /// one audition through the shared `NotePreviewPolicy` — reached over JNI as packed `channel, pitch` pairs.
    @Suite("onset preview bridge")
    struct OnsetPreviewBridgeTests {
        private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)

        /// A drum bar written as hands over feet: voice 1 crash (q) then rest (q), voice 2 kick (q) then kick (q).
        private static func score() -> Score {
            func chord(_ pitches: [Int]) -> VoiceElement {
                .chord(Chord(duration: .quarter, notes: ChordNotes(pitches.map { Note(pitch: $0, tpc: 14) })))
            }
            let hands = Voice(elements: [
                .timeSignature(TimeSignature(numerator: 2, denominator: 4)), chord([49]), chord([]),
            ])
            let feet = Voice(elements: [chord([36]), chord([36])])
            return Score(
                division: 480,
                parts: [Part(id: "drums", instrument: Instrument(id: "drumset"), staves: [
                    Staff(measures: [Measure(voices: [hands, feet])]),
                ])],
            )
        }

        private static func note(voice: Int, element: Int) -> NoteID {
            NoteID(staff: staff, measureIndex: 0, voiceIndex: voice, elementIndex: element, noteIndexInChord: 0)
        }

        @Test("a tap on the upper voice answers the lower voice starting with it")
        func onsetAcrossVoices() throws {
            let handle = scoreTable.insert(Self.score())
            defer { scoreTable.release(handle) }
            let bytes = nativeOnsetNoteItems(
                scoreHandle: handle, itemBytes: ScoreItemIDCodec.encode(.note(Self.note(voice: 0, element: 1))),
            )
            #expect(try ScoreItemIDCodec.decodeArray(bytes) == [
                .note(Self.note(voice: 0, element: 1)), .note(Self.note(voice: 1, element: 0)),
            ])
        }

        @Test("a tap on a rest answers what the other voice starts there")
        func onsetOfRest() throws {
            let handle = scoreTable.insert(Self.score())
            defer { scoreTable.release(handle) }
            let rest = RestID(staff: Self.staff, measureIndex: 0, voiceIndex: 0, elementIndex: 2)
            let bytes = nativeOnsetNoteItems(scoreHandle: handle, itemBytes: ScoreItemIDCodec.encode(.rest(rest)))
            #expect(try ScoreItemIDCodec.decodeArray(bytes) == [.note(Self.note(voice: 1, element: 1))])
        }

        @Test("an unknown handle answers nothing")
        func unknownHandle() {
            let bytes = nativeOnsetNoteItems(
                scoreHandle: -1, itemBytes: ScoreItemIDCodec.encode(.note(Self.note(voice: 0, element: 1))),
            )
            #expect(bytes.isEmpty)
        }

        @Test("the policy strikes, ends and silences every note of the audition")
        func policyRoundTrip() {
            let policy = nativePreviewPolicyCreate()
            defer { nativePreviewPolicyRelease(policyHandle: policy) }
            let crash = PreviewVoice(channel: 9, pitch: 49)
            let kick = PreviewVoice(channel: 9, pitch: 36)

            let first = nativePreviewPolicyBegin(
                policyHandle: policy, voices: PreviewVoicePairs.encode([crash, kick]), bends: Data(),
                velocity: 96, isDrum: true, ringMilliseconds: 500,
            )
            #expect(!first.isEmpty)
            #expect(PreviewVoicePairs.decode(nativePreviewPolicySilence(policyHandle: policy)) == [crash, kick])
            #expect(nativePreviewPolicySilence(policyHandle: policy).isEmpty)
        }

        @Test("an audition of no notes plans nothing")
        func emptyAudition() {
            let policy = nativePreviewPolicyCreate()
            defer { nativePreviewPolicyRelease(policyHandle: policy) }
            let plan = nativePreviewPolicyBegin(
                policyHandle: policy, voices: Data(), bends: Data(), velocity: 96, isDrum: false,
                ringMilliseconds: 500,
            )
            #expect(plan.isEmpty)
        }

        @Test("voice pairs round-trip")
        func pairsRoundTrip() {
            let voices = [PreviewVoice(channel: 0, pitch: 60), PreviewVoice(channel: 9, pitch: 36)]
            #expect(PreviewVoicePairs.decode(PreviewVoicePairs.encode(voices)) == voices)
        }

        @Test("bend pairs round-trip the whole 14-bit range")
        func bendPairsRoundTrip() {
            let bends: [UInt16] = [0, 7851, 8192, 16383]
            #expect(PreviewBendPairs.decode(PreviewBendPairs.encode(bends)) == bends)
        }

        /// The wheel crosses into the plan, so the Android engine moves it before the key — what the Apple engine does.
        @Test("a microtonal audition's plan carries the wheel to move")
        func planCarriesTheWheel() throws {
            let policy = nativePreviewPolicyCreate()
            defer { nativePreviewPolicyRelease(policyHandle: policy) }
            let voice = PreviewVoice(channel: 0, pitch: 71)

            let encoded = nativePreviewPolicyBegin(
                policyHandle: policy, voices: PreviewVoicePairs.encode([voice]),
                bends: PreviewBendPairs.encode([7851]), velocity: 96, isDrum: false, ringMilliseconds: 500,
            )

            var shared = NotePreviewPolicy()
            let planned = shared.begin(
                voices: [voice], bends: [7851], velocity: 96, isDrum: false, ringMilliseconds: 500,
            )
            let expected = try #require(planned)
            #expect(expected.pitchBends == [PreviewPitchBend(channel: 0, value: 7851)])
            #expect(encoded == PreviewPlanCodec.encode(expected))
        }
    }
#endif
