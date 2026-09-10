import Foundation
@testable import SheetMusicCore
import Testing

@Suite("Score fingerprint — parity fields")
struct ScoreFingerprintParityTests {
    private static let staff0 = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    private static let slot = VoiceElementID(staff: staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 1)

    #if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
        /// The committed standard chain's first fingerprint — `editReplay/goldens.txt` line 1 — computed from
        /// the in-memory fixture. Pins "a score with none of the new fields set hashes exactly as before"
        /// directly, so the by-occupants rule is checked here and not only through the golden suites.
        ///
        /// Apple-only because it reaches the goldens through `#filePath`, the same reason
        /// `ShippedMetricsTableTests` is: WASI has no preopened directory beyond the test bundle, so on the
        /// WebAssembly shape this reads as "the file doesn't exist" rather than as a fingerprint mismatch. The
        /// rest of this suite is in-memory and runs everywhere.
        @Test("a score with every new field at its default hashes exactly as it did before this change")
        func defaultsHashUnchanged() throws {
            let goldens = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Android/SheetMusicAndroid/src/androidTest/assets/editReplay/goldens.txt")
            let first = try String(contentsOf: goldens, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: true).first.flatMap { Int64($0) }
            #expect(EditingFixtures.replayFixture().stableFingerprint == first)
        }
    #endif

    /// `WritableKeyPath` is a class and does not conform to `Sendable`, which `@Test(arguments:)` requires of its
    /// elements — this wrapper carries the keypath across that boundary; it is safe because a keypath is
    /// immutable value-identity, never mutated after construction.
    private struct MeasureFlagKeyPath: @unchecked Sendable {
        let path: WritableKeyPath<Measure, Bool>
    }

    @Test("each measure flag moves the fingerprint, and clearing it moves it back", arguments: [
        MeasureFlagKeyPath(path: \Measure.lineBreak),
        MeasureFlagKeyPath(path: \Measure.pageBreak),
        MeasureFlagKeyPath(path: \Measure.sectionBreak),
        MeasureFlagKeyPath(path: \Measure.startRepeat),
    ])
    private func boolFlagsAreCovered(flag: MeasureFlagKeyPath) {
        var score = EditingFixtures.fourQuarterRests()
        let before = score.stableFingerprint
        score.parts.updateValue(at: 0) { partValue in
            partValue.staves.updateValue(at: 0) { staffValue in
                staffValue.measures[0][keyPath: flag.path] = true
            }
        }
        #expect(score.stableFingerprint != before)
        score.parts.updateValue(at: 0) { partValue in
            partValue.staves.updateValue(at: 0) { staffValue in
                staffValue.measures[0][keyPath: flag.path] = false
            }
        }
        #expect(score.stableFingerprint == before)
    }

    @Test("repeat counts, markers and jumps are covered and distinguishable")
    func countsMarkersJumps() {
        var score = EditingFixtures.fourQuarterRests()
        let before = score.stableFingerprint
        score.parts.updateValue(at: 0) { partValue in
            partValue.staves.updateValue(at: 0) { staffValue in
                staffValue.measures[0].endRepeatCount = 2
            }
        }
        let endRepeat = score.stableFingerprint
        #expect(endRepeat != before)
        score.parts.updateValue(at: 0) { partValue in
            partValue.staves.updateValue(at: 0) { staffValue in
                staffValue.measures[0].endRepeatCount = nil
            }
        }
        score.parts.updateValue(at: 0) { partValue in
            partValue.staves.updateValue(at: 0) { staffValue in
                staffValue.measures[0].measureRepeatCount = 2
            }
        }
        #expect(score.stableFingerprint != endRepeat, "same value under a different tag must differ")
        score.parts.updateValue(at: 0) { partValue in
            partValue.staves.updateValue(at: 0) { staffValue in
                staffValue.measures[0].measureRepeatCount = nil
            }
        }
        score.parts.updateValue(at: 0) { partValue in
            partValue.staves.updateValue(at: 0) { staffValue in
                staffValue.measures[0].markers = [Marker(kind: .coda, label: "codab")]
            }
        }
        let coda = score.stableFingerprint
        score.parts.updateValue(at: 0) { partValue in
            partValue.staves.updateValue(at: 0) { staffValue in
                staffValue.measures[0].markers = [Marker(kind: .segno, label: "segno")]
            }
        }
        #expect(score.stableFingerprint != coda)
        score.parts.updateValue(at: 0) { partValue in
            partValue.staves.updateValue(at: 0) { staffValue in
                staffValue.measures[0].markers = []
            }
        }
        score.parts.updateValue(at: 0) { partValue in
            partValue.staves.updateValue(at: 0) { staffValue in
                staffValue.measures[0].jumps = [
                    Jump(jumpTo: "start", playUntil: "fine", continueAt: "", playRepeats: false, text: "D.C."),
                ]
            }
        }
        #expect(score.stableFingerprint != before)
        score.parts.updateValue(at: 0) { partValue in
            partValue.staves.updateValue(at: 0) { staffValue in
                staffValue.measures[0].jumps = []
            }
        }
        #expect(score.stableFingerprint == before)
    }

    /// The symbol is fed BY OCCUPANTS: `.numeric` must leave the hash exactly where it was — that is what
    /// keeps every committed golden byte-identical — while any other symbol must move it, or a mirror that
    /// applied the meter without the C would agree with one that applied both.
    @Test("a time signature symbol moves the fingerprint, and .numeric leaves it alone")
    func timeSignatureSymbolIsCovered() {
        var score = EditingFixtures.fourQuarterRests()
        let before = score.stableFingerprint
        var seen: Set<Int64> = [before]
        for symbol in TimeSignatureSymbol.allCases where symbol != .numeric {
            score.parts.updateValue(at: 0) { partValue in
                partValue.staves.updateValue(at: 0) { staffValue in
                    staffValue.measures[0].voices[0].elements.updateValue(at: 0) {
                        $0 = .timeSignature(TimeSignature(numerator: 4, denominator: 4, symbol: symbol))
                    }
                }
            }
            let hash = score.stableFingerprint
            #expect(!seen.contains(hash), "\(symbol) must hash unlike every symbol before it")
            seen.insert(hash)
        }
        score.parts.updateValue(at: 0) { partValue in
            partValue.staves.updateValue(at: 0) { staffValue in
                staffValue.measures[0].voices[0].elements.updateValue(at: 0) {
                    $0 = .timeSignature(TimeSignature(numerator: 4, denominator: 4))
                }
            }
        }
        #expect(score.stableFingerprint == before)
    }

    @Test("a flag on measure 0 and the same flag on measure 1 hash differently")
    func flagsArePositional() {
        var a = EditingFixtures.twoMeasuresOfQuarterRests(key: 0)
        var b = a
        a.parts.updateValue(at: 0) { partValue in
            partValue.staves.updateValue(at: 0) { staffValue in
                staffValue.measures[0].lineBreak = true
            }
        }
        b.parts.updateValue(at: 0) { partValue in
            partValue.staves.updateValue(at: 0) { staffValue in
                staffValue.measures[1].lineBreak = true
            }
        }
        #expect(a.stableFingerprint != b.stableFingerprint)
    }

    @Test("the marker VoiceElement cases now carry their content")
    func markerCasesCarryContent() {
        var score = EditingFixtures.fourQuarterRests()
        score[Self.slot] = .dynamic(Dynamic(subtype: "p", velocity: 49))
        let piano = score.stableFingerprint
        score[Self.slot] = .dynamic(Dynamic(subtype: "f", velocity: 96))
        #expect(score.stableFingerprint != piano)
        score[Self.slot] = .barLine(BarLine(subtype: "double"))
        let double = score.stableFingerprint
        score[Self.slot] = .barLine(BarLine(subtype: "end"))
        #expect(score.stableFingerprint != double)
        score[Self.slot] = .clef(Clef(concertClefType: "G"))
        let treble = score.stableFingerprint
        score[Self.slot] = .clef(Clef(concertClefType: "F"))
        #expect(score.stableFingerprint != treble)
        score[Self.slot] = .harmony(Harmony(name: "C"))
        let cMajor = score.stableFingerprint
        score[Self.slot] = .harmony(Harmony(name: "Am7"))
        #expect(score.stableFingerprint != cMajor)
        score[Self.slot] = .harmony(Harmony(name: "C", harmonyType: .roman))
        #expect(score.stableFingerprint != cMajor)
    }

    @Test("chord and note element properties are covered by occupants")
    func elementPropertiesCovered() {
        var score = EditingFixtures.chordAtIndex1()
        let before = score.stableFingerprint
        guard case var .chord(chord) = score[Self.slot] else { Issue.record("expected a chord"); return }
        chord.visible = false
        score[Self.slot] = .chord(chord)
        #expect(score.stableFingerprint != before)
        chord.visible = true
        chord.notes[0].elementProperties.color = ScoreColor(red: 255, green: 0, blue: 0, alpha: 255)
        score[Self.slot] = .chord(chord)
        #expect(score.stableFingerprint != before)
        chord.notes[0].elementProperties.color = nil
        score[Self.slot] = .chord(chord)
        #expect(score.stableFingerprint == before)
    }

    @Test("element placement moves the fingerprint, and clearing it moves it back")
    func elementPlacementIsDisplayTrivia() {
        // Inverted in selection-and-editing Phase 0 (2026-09-10): placement is editable state,
        // so treating it as display trivia would let a replay mirror pass after a failed write.
        let plain = EditingFixtures.chordAtIndex1()
        var placed = plain
        guard case var .chord(chord) = placed[Self.slot] else {
            Issue.record("expected a chord")
            return
        }
        chord.elementProperties.placement = Placement.above
        placed[Self.slot] = .chord(chord)
        let above = placed.stableFingerprint
        #expect(above != plain.stableFingerprint)
        chord.elementProperties.placement = Placement.below
        placed[Self.slot] = .chord(chord)
        #expect(placed.stableFingerprint != plain.stableFingerprint)
        #expect(placed.stableFingerprint != above)
        chord.elementProperties.placement = nil
        placed[Self.slot] = .chord(chord)
        #expect(placed.stableFingerprint == plain.stableFingerprint)
    }

    @Test("harmony color moves the fingerprint, and clearing it moves it back")
    func harmonyColorIsCovered() {
        var score = EditingFixtures.fourQuarterRests()
        var harmony = Harmony(name: "C")
        score[Self.slot] = .harmony(harmony)
        let before = score.stableFingerprint
        var seen: Set<Int64> = [before]
        for color in [
            ScoreColor(red: 0, green: 0, blue: 0, alpha: 0),
            ScoreColor(red: 1, green: 0, blue: 0, alpha: 0),
            ScoreColor(red: 0, green: 1, blue: 0, alpha: 0),
            ScoreColor(red: 0, green: 0, blue: 1, alpha: 0),
            ScoreColor(red: 0, green: 0, blue: 0, alpha: 1),
        ] {
            harmony.color = color
            score[Self.slot] = .harmony(harmony)
            #expect(seen.insert(score.stableFingerprint).inserted, "presence and every RGBA channel must count")
        }
        harmony.color = nil
        score[Self.slot] = .harmony(harmony)
        #expect(score.stableFingerprint == before)
    }

    @Test("placement alone reaches an otherwise default fret diagram")
    func defaultFretDiagramPlacementIsCovered() {
        var score = EditingFixtures.fourQuarterRests()
        var diagram = FretDiagram()
        score[Self.slot] = .fretDiagram(diagram)
        let before = score.stableFingerprint
        diagram.elementProperties.placement = .above
        score[Self.slot] = .fretDiagram(diagram)
        #expect(score.stableFingerprint != before)
        diagram.elementProperties.placement = nil
        score[Self.slot] = .fretDiagram(diagram)
        #expect(score.stableFingerprint == before)
    }

    /// Every kind `SetTextVisible` (intent 75) can hide moves the fingerprint, and showing it again moves it
    /// back. Without this the JNI / web replay chains would report two images as agreeing after one of them had
    /// failed to apply a hide — the exact false pass `ScoreFingerprint.swift`'s blind-spot list warns about, and
    /// the reason three of these four fields entered the walk with this command.
    @Test("hiding each kind of engraved text moves the fingerprint, and showing it moves it back")
    func textVisibilityIsCovered() throws {
        var score = EditingFixtures.twoConsecutiveC4Chords()
        let second = VoiceElementID(staff: Self.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 2)
        _ = try SetLyric(at: Self.slot, verse: 0, text: "la", syllabic: .single).apply(to: &score)
        _ = try SetStaffText(anchor: second, text: "pizz.", isSystemText: false).apply(to: &score)
        _ = try SetRehearsalMark(measureIndex: 0, text: "A").apply(to: &score)
        _ = try SetChordSymbol(at: Self.slot, name: "Am7").apply(to: &score)
        // The symbol insert shifted both chords one slot right.
        let shifted = VoiceElementID(staff: Self.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 2)
        let ids: [ScoreTextID] = [
            .lyric(anchor: shifted, verse: 0),
            .staffText(anchor: VoiceElementID(
                staff: Self.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 3,
            ), style: .staffText),
            .harmony(anchor: shifted),
            .rehearsalMark(measureIndex: 0),
        ]
        for id in ids {
            let before = score.stableFingerprint
            let inverse = try SetTextVisible(id, visible: false).apply(to: &score)
            #expect(score.stableFingerprint != before, "hiding \(id) should move the fingerprint")
            _ = try inverse.apply(to: &score)
            #expect(score.stableFingerprint == before, "showing \(id) should restore the fingerprint")
        }
    }
}
