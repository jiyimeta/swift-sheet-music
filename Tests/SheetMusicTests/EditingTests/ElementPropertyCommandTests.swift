@testable import SheetMusicCore
import SheetMusicMSCX
import Testing

@Suite("Element property commands")
struct ElementPropertyCommandTests {
    private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    private static let chord = VoiceElementID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 2)
    private static let note = NoteID(
        staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 2, noteIndexInChord: 1,
    )
    private static let color = ScoreColor(red: 17, green: 34, blue: 51, alpha: 68)

    /// The symbol occupies slot 1; both lyrics and both notes belong to the chord in slot 2.
    /// Staff/system texts share a beat and must remain independent. The rehearsal mark belongs to their bar.
    private static func populated() throws -> Score {
        var score = EditingFixtures.twoConsecutiveC4Chords()
        let anchor = VoiceElementID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 1)
        guard case var .chord(value)? = score[anchor] else { throw SetElementVisible.refused(.targetNotFound(anchor)) }
        value.notes = ChordNotes(Array(value.notes) + [Note(pitch: 64, tpc: 18)])
        score[anchor] = .chord(value)
        try SetLyric(at: anchor, verse: 0, text: "la", syllabic: .single).apply(to: &score)
        try SetLyric(at: anchor, verse: 1, text: "lo", syllabic: .single).apply(to: &score)
        try SetStaffText(anchor: anchor, text: "pizz.", isSystemText: false).apply(to: &score)
        try SetStaffText(anchor: anchor, text: "Swing", isSystemText: true).apply(to: &score)
        try SetRehearsalMark(measureIndex: 0, text: "A").apply(to: &score)
        try SetChordSymbol(at: anchor, name: "Am7").apply(to: &score)
        return score
    }

    private static let colors: [SetElementColor.Target] = [
        .text(.lyric(anchor: chord, verse: 1)),
        .text(.staffText(anchor: chord, style: .staffText)),
        .text(.staffText(anchor: chord, style: .systemText)),
        .text(.harmony(anchor: chord)),
        .text(.rehearsalMark(measureIndex: 0)),
        .note(note),
    ]
    private static let placements: [SetElementPlacement.Target] = [
        .text(.lyric(anchor: chord, verse: 1)),
        .text(.staffText(anchor: chord, style: .staffText)),
        .text(.staffText(anchor: chord, style: .systemText)),
        .text(.harmony(anchor: chord)),
        .text(.rehearsalMark(measureIndex: 0)),
        .note(note),
        .chord(chord),
    ]

    /// Independent fixture writes: no production locator or command reader constructs the expected score.
    private static func change(
        _ index: Int, in score: inout Score, _ update: (inout ElementProperties) -> Void,
    ) throws {
        switch index {
        case 0, 5, 6:
            guard case var .chord(value)? = score[chord] else { Issue.record("missing chord"); return }
            if index == 0 { update(&value.lyrics[1].elementProperties) }
            if index == 5 { value.notes.updateNote(at: 1) { update(&$0.elementProperties) } }
            if index == 6 { update(&value.elementProperties) }
            score[chord] = .chord(value)
        case 1, 2:
            let laneIndex = try #require(score.systemMeasures[0].elements.firstIndex {
                if case let .staffText(text) = $0.element { text.isSystemText == (index == 2) } else { false }
            })
            guard case var .staffText(text) = score.systemMeasures[0].elements[laneIndex].element else { return }
            update(&text.elementProperties)
            score.systemMeasures.updateValue(at: 0) {
                $0.elements.updateValue(at: laneIndex) { $0.element = .staffText(text) }
            }
        case 3:
            let slot = VoiceElementID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 1)
            guard case var .harmony(value)? = score[slot] else { Issue.record("missing symbol"); return }
            update(&value.elementProperties)
            score[slot] = .harmony(value)
        case 4:
            let laneIndex = try #require(score.systemMeasures[0].elements.firstIndex {
                if case .rehearsalMark = $0.element { true } else { false }
            })
            guard case var .rehearsalMark(mark) = score.systemMeasures[0].elements[laneIndex].element else { return }
            update(&mark.elementProperties)
            score.systemMeasures.updateValue(at: 0) {
                $0.elements.updateValue(at: laneIndex) { $0.element = .rehearsalMark(mark) }
            }
        default:
            Issue.record("unknown fixture carrier")
        }
    }

    @Test(
        "color writes only the addressed carrier, and every inverse restores its fingerprint",
        arguments: 0 ..< 6,
    )
    func colorRoundTrip(index: Int) throws {
        var score = try Self.populated()
        try Self.change(index, in: &score) {
            $0.visible = false
            $0.offset = ScoreOffset(x: 1.25, y: -2.5)
            $0.placement = .below
        }
        let values: [ScoreColor?] = [
            Self.color, ScoreColor(red: 18, green: 34, blue: 51, alpha: 68),
            ScoreColor(red: 18, green: 35, blue: 51, alpha: 68),
            ScoreColor(red: 18, green: 35, blue: 52, alpha: 68),
            ScoreColor(red: 18, green: 35, blue: 52, alpha: 69), nil,
        ]
        for color in values {
            let before = score
            var expected = before
            try Self.change(index, in: &expected) { $0.color = color }
            let inverse = try SetElementColor(Self.colors[index], color: color).apply(to: &score)
            #expect(score == expected)
            #expect(score.stableFingerprint != before.stableFingerprint)
            let redo = try inverse.apply(to: &score)
            #expect(score == before)
            #expect(score.stableFingerprint == before.stableFingerprint)
            try redo.apply(to: &score)
            #expect(score == expected)
        }
    }

    @Test(
        "placement writes only the addressed carrier, and every inverse restores its fingerprint",
        arguments: 0 ..< 7,
    )
    func placementRoundTrip(index: Int) throws {
        var score = try Self.populated()
        try Self.change(index, in: &score) {
            $0.color = Self.color
            $0.visible = false
            $0.offset = ScoreOffset(x: 1.25, y: -2.5)
        }
        let values: [Placement?] = [.above, .below, nil]
        for placement in values {
            let before = score
            var expected = before
            try Self.change(index, in: &expected) { $0.placement = placement }
            let inverse = try SetElementPlacement(Self.placements[index], placement: placement).apply(to: &score)
            #expect(score == expected)
            #expect(score.stableFingerprint != before.stableFingerprint)
            let redo = try inverse.apply(to: &score)
            #expect(score == before)
            #expect(score.stableFingerprint == before.stableFingerprint)
            try redo.apply(to: &score)
            #expect(score == expected)
        }
    }

    @Test("color planning skips existing values including nil", arguments: 0 ..< 6)
    func colorPlanning(index: Int) throws {
        var score = try Self.populated()
        let target = Self.colors[index]
        let clear = EditIntent.setElementColor(target: target, color: nil)
        #expect(try ScoreEditSession.command(for: clear, in: score, ids: EIDAllocator(), depth: 0) == nil)
        let intent = EditIntent.setElementColor(target: target, color: Self.color)
        let planned = try #require(try ScoreEditSession.command(for: intent, in: score, ids: EIDAllocator(), depth: 0))
        #expect(planned is SetElementColor)
        try planned.apply(to: &score)
        #expect(try ScoreEditSession.command(for: intent, in: score, ids: EIDAllocator(), depth: 0) == nil)
        #expect(try ScoreEditSession.command(for: clear, in: score, ids: EIDAllocator(), depth: 0) is SetElementColor)
    }

    @Test("placement planning skips existing values including nil", arguments: 0 ..< 7)
    func placementPlanning(index: Int) throws {
        var score = try Self.populated()
        let target = Self.placements[index]
        let clear = EditIntent.setElementPlacement(target: target, placement: nil)
        #expect(try ScoreEditSession.command(for: clear, in: score, ids: EIDAllocator(), depth: 0) == nil)
        let intent = EditIntent.setElementPlacement(target: target, placement: .below)
        let planned = try #require(try ScoreEditSession.command(for: intent, in: score, ids: EIDAllocator(), depth: 0))
        #expect(planned is SetElementPlacement)
        try planned.apply(to: &score)
        #expect(try ScoreEditSession.command(for: intent, in: score, ids: EIDAllocator(), depth: 0) == nil)
        #expect(try ScoreEditSession.command(
            for: clear, in: score, ids: EIDAllocator(), depth: 0,
        ) is SetElementPlacement)
    }

    @Test("missing targets still plan commands, even when clearing nil")
    func staleTargetsAreRefused() throws {
        let score = ScoreEditor(score: EditingFixtures.twoConsecutiveC4Chords()).score
        let texts: [ScoreTextID] = [
            .lyric(anchor: Self.chord, verse: 9),
            .staffText(anchor: Self.chord, style: .staffText),
            .harmony(anchor: Self.chord), .rehearsalMark(measureIndex: 9),
        ]
        var intents = texts.flatMap { text in
            [
                EditIntent.setElementColor(target: .text(text), color: nil),
                EditIntent.setElementPlacement(target: .text(text), placement: nil),
                EditIntent.setTextOffset(text: text, offset: nil),
                EditIntent.setTextAutoplace(text: text, autoplace: nil),
            ]
        }
        intents += [
            .setElementColor(target: .note(Self.note), color: nil),
            .setElementPlacement(target: .note(Self.note), placement: nil),
            .setElementPlacement(target: .chord(VoiceElementID(
                staff: Self.staff, measureIndex: 99, voiceIndex: 0, elementIndex: 0,
            )), placement: nil),
            .setElementPlacement(target: .chord(VoiceElementID(
                staff: Self.staff, measureIndex: 0, voiceIndex: 0, elementIndex: 0,
            )), placement: nil),
        ]
        for intent in intents {
            var scratch = score
            let command = try #require(try ScoreEditSession.command(
                for: intent, in: score, ids: EIDAllocator(), depth: 0,
            ))
            #expect(throws: SheetMusicError.self) { try command.apply(to: &scratch) }
            #expect(scratch == score)
        }
    }

    @Test("affected locations keep the actual note/chord slot and the rehearsal bar approximation")
    func affectedLocations() {
        #expect(SetElementColor(.note(Self.note), color: nil).affectedLocation == Self.chord)
        #expect(SetElementPlacement(.chord(Self.chord), placement: nil).affectedLocation == Self.chord)
        let target = ScoreTextID.rehearsalMark(measureIndex: 3)
        #expect(SetElementColor(.text(target), color: nil).affectedLocation.measureIndex == 3)
        #expect(SetElementPlacement(.text(target), placement: nil).affectedLocation.measureIndex == 3)
    }

    @Test("the session retains one undo step across a repeated write")
    func sessionUndoAndNoOp() throws {
        let before = try Self.populated()
        let intents: [EditIntent] = [
            .setElementColor(target: Self.colors[3], color: Self.color),
            .setElementPlacement(target: Self.placements[4], placement: .below),
        ]
        for intent in intents {
            let session = ScoreEditSession(score: before)
            #expect(session.apply(intent))
            let after = session.score
            #expect(after.stableFingerprint != before.stableFingerprint)
            #expect(!session.apply(intent))
            #expect(session.lastRefusal?.reason == .nothingToApply)
            #expect(session.undo())
            #expect(session.score == before)
            #expect(!session.undo())
            #expect(session.redo())
            #expect(session.score == after)
        }
    }

    @Test("a whole-chord placement also addresses a rest without creating notes")
    func restPlacement() throws {
        var score = EditingFixtures.fourQuarterRests()
        let before = score
        let inverse = try SetElementPlacement(.chord(Self.chord), placement: .below).apply(to: &score)
        guard case let .chord(rest)? = score[Self.chord] else { Issue.record("missing rest"); return }
        #expect(rest.notes.isEmpty)
        #expect(rest.elementProperties.placement == .below)
        #expect(score.stableFingerprint != before.stableFingerprint)
        try inverse.apply(to: &score)
        #expect(score == before)
        #expect(score.stableFingerprint == before.stableFingerprint)
    }

    @Test("refusal distinguishes an absent note, an absent target, and a wrong chord kind")
    func refusalReasons() {
        let session = ScoreEditSession(score: EditingFixtures.twoConsecutiveC4Chords())
        #expect(!session.apply(.setElementColor(target: .note(Self.note), color: nil)))
        #expect(session.lastRefusal?.reason == .noteNotFound(Self.note))
        #expect(!session.apply(.setElementPlacement(target: .note(Self.note), placement: nil)))
        #expect(session.lastRefusal?.reason == .noteNotFound(Self.note))
        let mark = ScoreTextID.rehearsalMark(measureIndex: 9)
        let location = VoiceElementID(staff: Self.staff, measureIndex: 9, voiceIndex: 0, elementIndex: 0)
        #expect(!session.apply(.setElementColor(target: .text(mark), color: nil)))
        #expect(session.lastRefusal?.reason == .targetNotFound(location))
        #expect(!session.apply(.setElementPlacement(target: .text(mark), placement: nil)))
        #expect(session.lastRefusal?.reason == .targetNotFound(location))
        let signature = VoiceElementID(staff: Self.staff, measureIndex: 0, voiceIndex: 0, elementIndex: 0)
        #expect(!session.apply(.setElementPlacement(target: .chord(signature), placement: nil)))
        #expect(session.lastRefusal?.reason == .wrongElementKind(at: signature, expected: .chordOrRest))
    }

    private static let texts: [ScoreTextID] = [
        .lyric(anchor: chord, verse: 1),
        .staffText(anchor: chord, style: .staffText),
        .staffText(anchor: chord, style: .systemText),
        .harmony(anchor: chord),
        .rehearsalMark(measureIndex: 0),
    ]

    @Test("offset is written to each text kind and the inverse restores it", arguments: texts)
    func offsetRoundTrips(_ target: ScoreTextID) throws {
        var score = try Self.populated()
        let offset = ScoreOffset(x: 1.5, y: -2.25)
        let inverse = try SetTextOffset(target, offset: offset).apply(to: &score)
        #expect(SetTextOffset.currentProperties(for: target, in: score)?.offset == offset)
        try inverse.apply(to: &score)
        #expect(SetTextOffset.currentProperties(for: target, in: score)?.offset == nil)
    }

    @Test("auto-place is written to each text kind and the inverse restores it", arguments: texts)
    func autoplaceRoundTrips(_ target: ScoreTextID) throws {
        var score = try Self.populated()
        let inverse = try SetTextAutoplace(target, autoplace: false).apply(to: &score)
        #expect(SetTextAutoplace.currentProperties(for: target, in: score)?.autoplace == false)
        try inverse.apply(to: &score)
        #expect(SetTextAutoplace.currentProperties(for: target, in: score)?.autoplace == nil)
    }

    /// The distinction the planner depends on: an ABSENT carrier is refused, an inherited value is not.
    @Test("an absent carrier is refused, and clearing an already-clear value succeeds")
    func absentIsRefusedAndClearingIsNot() throws {
        var score = try Self.populated()
        let missingVerse = ScoreTextID.lyric(anchor: Self.chord, verse: 9)
        let offsetError = #expect(throws: SheetMusicError.self) {
            try SetTextOffset(missingVerse, offset: nil).apply(to: &score)
        }
        guard case let .invalidEdit(offsetRefusal)? = offsetError else { Issue.record("expected refusal"); return }
        // `TextElementProperties.update` reports absence as `false` and lets the caller throw with its own
        // name, so the stamped operation must be the calling command, not the shared helper.
        #expect(offsetRefusal.operation == "SetTextOffset")
        let autoplaceError = #expect(throws: SheetMusicError.self) {
            try SetTextAutoplace(missingVerse, autoplace: nil).apply(to: &score)
        }
        guard case let .invalidEdit(autoplaceRefusal)? = autoplaceError else {
            Issue.record("expected refusal")
            return
        }
        #expect(autoplaceRefusal.operation == "SetTextAutoplace")

        let present = ScoreTextID.lyric(anchor: Self.chord, verse: 1)
        #expect(SetTextOffset.currentProperties(for: present, in: score)?.offset == nil)
        try SetTextOffset(present, offset: nil).apply(to: &score)
        try SetTextAutoplace(present, autoplace: nil).apply(to: &score)
    }

    /// Writing one text's offset must not touch the other text sharing its beat.
    @Test("staff text and system text keep independent offsets")
    func staffAndSystemTextAreIndependent() throws {
        var score = try Self.populated()
        let staffText = ScoreTextID.staffText(anchor: Self.chord, style: .staffText)
        let systemText = ScoreTextID.staffText(anchor: Self.chord, style: .systemText)
        try SetTextOffset(staffText, offset: ScoreOffset(x: 3, y: 4)).apply(to: &score)
        #expect(SetTextOffset.currentProperties(for: staffText, in: score)?.offset
            == ScoreOffset(x: 3, y: 4))
        #expect(SetTextOffset.currentProperties(for: systemText, in: score)?.offset == nil)
    }

    /// The four fields already round-trip; what this pins is that the COMMANDS write the same field the codec
    /// reads. A command writing a lookalike would pass every in-memory test above and lose the value on save.
    @Test("offset and auto-place written by command survive an MSCX round trip")
    func survivesMSCXRoundTrip() throws {
        var score = try Self.populated()
        let lyric = ScoreTextID.lyric(anchor: Self.chord, verse: 1)
        try SetTextOffset(lyric, offset: ScoreOffset(x: 1.5, y: -2)).apply(to: &score)
        try SetTextAutoplace(lyric, autoplace: false).apply(to: &score)

        let reloaded = try MSCXParser.parse(MSCXEncoder.encode(score))
        #expect(SetTextOffset.currentProperties(for: lyric, in: reloaded)?.offset
            == ScoreOffset(x: 1.5, y: -2))
        #expect(SetTextAutoplace.currentProperties(for: lyric, in: reloaded)?.autoplace == false)
    }
}
