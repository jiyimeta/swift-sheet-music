// Guarded because this reads and rewrites fixtures in the checkout through
// `#filePath`. A WASI test host has no preopened directory beyond the
// SwiftPM test bundle, so a recorder that writes into `Web/sheet-music-web`
// cannot run there by nature. The condition stands in for host-filesystem
// access here, the same way `BravuraMetricsTableTests` uses it.
#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicCore
    import SheetMusicEditWire
    @testable import SheetMusicMSCX
    import Testing

    @Suite("Edit replay web goldens")
    struct EditReplayWebGoldenTests {
        private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)

        private var packageRoot: URL {
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent() // EditingTests
                .deletingLastPathComponent() // SheetMusicTests
                .deletingLastPathComponent() // Tests
                .deletingLastPathComponent() // package root
        }

        private var webFixturesDir: URL {
            packageRoot.appendingPathComponent("Web/sheet-music-web/test/fixtures")
        }

        private var androidGoldensPath: URL {
            packageRoot.appendingPathComponent(
                "Android/SheetMusicAndroid/src/androidTest/assets/editReplay/goldens.txt",
            )
        }

        @Test("record or verify web replay fixture against the Android fingerprint chain")
        func replayFixtureMatchesLiveScriptAndAndroidGoldens() throws {
            let liveFixtureData = try MSCXEncoder.encode(EditingFixtures.replayFixture())
            let steps = EditReplayScript.standard(staff: Self.staff)
            let replay = try makeReplayFixture(steps: steps, fixtureData: liveFixtureData)

            let isRecording = ProcessInfo.processInfo.environment["SM_EDIT_REPLAY_RECORD"] == "1"
            if isRecording {
                try record(fixtureData: liveFixtureData, replay: replay)
            }

            try verify(fixtureData: liveFixtureData, replay: replay)
        }

        private func makeReplayFixture(steps: [EditReplayStep], fixtureData: Data) throws -> ReplayFixture {
            let score = try MSCXParser.parse(fixtureData)
            let session = ScoreEditSession(score: score)
            var fingerprints = [String(session.score.stableFingerprint)]
            var encodedSteps: [ReplayStep] = []

            for step in steps {
                switch step {
                case let .intent(intent):
                    let encoded = try ReplayStep(intent: intent)
                    #expect(
                        session.apply(intent),
                        "live replay step \(encoded.op) refused while generating web goldens",
                    )
                    encodedSteps.append(encoded)
                case .undo:
                    #expect(session.undo(), "live replay undo refused while generating web goldens")
                    encodedSteps.append(ReplayStep(op: "undo"))
                case .redo:
                    #expect(session.redo(), "live replay redo refused while generating web goldens")
                    encodedSteps.append(ReplayStep(op: "redo"))
                }
                fingerprints.append(String(session.score.stableFingerprint))
            }

            #expect(fingerprints.count == steps.count + 1)
            return ReplayFixture(fingerprints: fingerprints, steps: encodedSteps)
        }

        private func record(fixtureData: Data, replay: ReplayFixture) throws {
            try FileManager.default.createDirectory(at: webFixturesDir, withIntermediateDirectories: true)
            try fixtureData.write(to: webFixturesDir.appendingPathComponent("edit-replay.mscx"))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(replay).write(to: webFixturesDir.appendingPathComponent("edit-replay.json"))
        }

        private func verify(fixtureData: Data, replay: ReplayFixture) throws {
            let committedFixture = try Data(contentsOf: webFixturesDir.appendingPathComponent("edit-replay.mscx"))
            #expect(committedFixture == fixtureData, "edit-replay.mscx drifted from the live replay fixture")

            let decoder = JSONDecoder()
            let committedReplay = try decoder.decode(
                ReplayFixture.self,
                from: Data(contentsOf: webFixturesDir.appendingPathComponent("edit-replay.json")),
            )
            #expect(committedReplay == replay, "edit-replay.json drifted from the live replay script")

            let androidFingerprints = try String(contentsOf: androidGoldensPath, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
            #expect(
                androidFingerprints == replay.fingerprints,
                "web edit replay fingerprints drifted from Android editReplay/goldens.txt",
            )
        }
    }

    private struct ReplayFixture: Codable, Equatable {
        let fingerprints: [String]
        let steps: [ReplayStep]
    }

    private struct ReplayStep: Codable, Equatable {
        var op: String
        var at: ElementPath?
        var from: NotePath?
        var to: NotePath?
        var pitch: Int?
        var tpc: Int?
        var accidental: String?
        var duration: DurationSpec?
        var actualNotes: Int?
        var normalNotes: Int?
        var sourceTieForward: Int?
        var targetTieBack: Int?
        var base64: String?

        init(op: String) {
            self.op = op
        }

        /// Exhaustive over `EditIntent` on purpose: a new case has to be given a
        /// serialized form here before the replay fixture can carry it, and the
        /// compiler is what enforces that. Splitting the switch to satisfy the
        /// length rule would hide the exhaustiveness, which is the only thing
        /// this initializer is for.
        init(intent: EditIntent) throws { // swiftlint:disable:this function_body_length
            switch intent {
            case let .inputNote(at, pitch, tpc, duration):
                self.init(op: "inputNote")
                self.at = ElementPath(at)
                self.pitch = pitch
                self.tpc = tpc
                self.duration = duration.map(DurationSpec.init)
            case let .writeNote(at, pitch, tpc, duration):
                self.init(op: "writeNote")
                self.at = ElementPath(at)
                self.pitch = pitch
                self.tpc = tpc
                self.duration = duration.map(DurationSpec.init)
            case let .writeRest(at, duration):
                self.init(op: "writeRest")
                self.at = ElementPath(at)
                self.duration = DurationSpec(duration)
            case let .setNotePitch(at, pitch, tpc, accidental):
                self.init(op: "setNotePitch")
                self.at = ElementPath(at)
                self.pitch = pitch
                self.tpc = tpc
                self.accidental = accidental?.rawValue
            case let .setAccidental(at, accidental):
                self.init(op: "setAccidental")
                self.at = ElementPath(at)
                self.accidental = accidental?.rawValue
            case let .addNoteToChord(at, pitch, tpc, accidental):
                self.init(op: "addNoteToChord")
                self.at = ElementPath(at)
                self.pitch = pitch
                self.tpc = tpc
                self.accidental = accidental?.rawValue
            case let .removeNoteFromChord(at):
                self.init(op: "removeNoteFromChord")
                self.at = ElementPath(at)
            case let .setTie(from, to, sourceTieForward, targetTieBack):
                self.init(op: "setTie")
                self.from = NotePath(from)
                self.to = NotePath(to)
                self.sourceTieForward = sourceTieForward
                self.targetTieBack = targetTieBack
            case let .setRestDuration(at, duration):
                self.init(op: "setRestDuration")
                self.at = ElementPath(at)
                self.duration = DurationSpec(duration)
            case let .setChordDuration(at, duration):
                self.init(op: "setChordDuration")
                self.at = ElementPath(at)
                self.duration = DurationSpec(duration)
            case let .delete(at):
                self.init(op: "delete")
                self.at = ElementPath(at)
            case let .createTuplet(at, actualNotes, normalNotes):
                self.init(op: "createTuplet")
                self.at = ElementPath(at)
                self.actualNotes = actualNotes
                self.normalNotes = normalNotes
            case let .removeTuplet(at):
                self.init(op: "removeTuplet")
                self.at = ElementPath(at)
            case .composite, .insertMeasure, .deleteMeasure, .addPart, .removePart, .movePart,
                 .setKeySignature, .removeKeySignature, .setTimeSignature, .removeTimeSignature,
                 .setRehearsalMark, .removeRehearsalMark,
                 .createVoice, .splitRest, .setNoteHead, .setDrumsetEntry:
                self.init(op: "intentBytes")
                base64 = EditIntentCodec.encode(intent).base64EncodedString()
            }
        }
    }

    private struct ElementPath: Codable, Equatable {
        let partIndex: Int
        let staffIndexInPart: Int
        let measureIndex: Int
        let voiceIndex: Int
        let elementIndex: Int
        let noteIndexInChord: Int?

        init(_ id: VoiceElementID) {
            partIndex = id.staff.partIndex
            staffIndexInPart = id.staff.staffIndexInPart
            measureIndex = id.measureIndex
            voiceIndex = id.voiceIndex
            elementIndex = id.elementIndex
            noteIndexInChord = nil
        }

        init(_ id: RestID) {
            partIndex = id.staff.partIndex
            staffIndexInPart = id.staff.staffIndexInPart
            measureIndex = id.measureIndex
            voiceIndex = id.voiceIndex
            elementIndex = id.elementIndex
            noteIndexInChord = nil
        }

        init(_ id: NoteID) {
            partIndex = id.staff.partIndex
            staffIndexInPart = id.staff.staffIndexInPart
            measureIndex = id.measureIndex
            voiceIndex = id.voiceIndex
            elementIndex = id.elementIndex
            noteIndexInChord = id.noteIndexInChord
        }
    }

    private typealias NotePath = ElementPath

    private struct DurationSpec: Codable, Equatable {
        var value: String?
        var numerator: Int?
        var denominator: Int?

        init(_ duration: NoteDuration) {
            switch duration {
            case .whole: value = "whole"
            case .half: value = "half"
            case .quarter: value = "quarter"
            case .eighth: value = "eighth"
            case .sixteenth: value = "sixteenth"
            case .thirtySecond: value = "thirtySecond"
            case .sixtyFourth: value = "sixtyFourth"
            case .oneTwentyEighth: value = "oneTwentyEighth"
            case .twoFiftySixth: value = "twoFiftySixth"
            case .measure: value = "measure"
            case let .fraction(fraction):
                numerator = fraction.numerator
                denominator = fraction.denominator
            }
        }
    }
#endif
