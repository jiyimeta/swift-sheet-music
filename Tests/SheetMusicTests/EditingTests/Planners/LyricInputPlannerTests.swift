@testable import SheetMusicCore
import Testing

@Suite("LyricInputPlanner")
struct LyricInputPlannerTests {
    private static let syllabics: [Syllabic] = [.single, .begin, .middle, .end]
    private static let first = id(element: 1)
    private static let second = id(element: 2)

    @Test("Space repairs all 16 existing from-to syllabic pairs")
    func wordTransitions() throws {
        try assertTransitionTable(
            terminator: .word,
            expectedFrom: [.single, .single, .end, .end],
            expectedTo: [.single, .begin, .begin, .single],
            expectedFromTicks: 0,
        )
    }

    @Test("hyphen repairs all 16 existing from-to syllabic pairs")
    func syllableTransitions() throws {
        try assertTransitionTable(
            terminator: .syllable,
            expectedFrom: [.begin, .begin, .middle, .middle],
            expectedTo: [.end, .middle, .middle, .end],
            expectedFromTicks: 0,
        )
    }

    @Test("underscore repairs all 16 existing from-to syllabic pairs")
    func melismaTransitions() throws {
        try assertTransitionTable(
            terminator: .melisma,
            expectedFrom: [.single, .end, .end, .end],
            expectedTo: [.single, .begin, .begin, .single],
            expectedFromTicks: 480,
        )
    }

    @Test("an absent destination plans no to command for every advancing terminator")
    func absentDestinationPlansNoRepair() throws {
        for terminator in [
            LyricInputPlanner.Terminator.word,
            .syllable,
            .melisma,
        ] {
            var score = EditingFixtures.twoConsecutiveC4Chords()
            Self.setLyrics([Lyric(text: "from", syllabic: .middle, ticks: 96)], at: Self.first, in: &score)

            let plan = LyricInputPlanner.plan(
                typing: "from",
                terminatedBy: terminator,
                at: .init(location: Self.first, verse: 0),
                in: score,
            )

            #expect(plan.next == .init(location: Self.second, verse: 0))
            #expect(plan.command.map { $0 is SetLyric } == true)
            try Self.apply(plan, to: &score)
            #expect(LyricInputPlanner.lyric(at: .init(location: Self.second, verse: 0), in: score) == nil)
        }
    }

    @Test("a new syllable derives its opening state from the preceding non-empty syllable")
    func newSyllableRule() throws {
        let cases: [(Syllabic?, Syllabic)] = [
            (nil, .single),
            (.single, .single),
            (.begin, .end),
            (.middle, .end),
            (.end, .single),
        ]
        for (preceding, expected) in cases {
            var score = EditingFixtures.twoConsecutiveC4Chords()
            if let preceding {
                Self.setLyrics([Lyric(text: "prior", syllabic: preceding)], at: Self.first, in: &score)
            }

            let plan = LyricInputPlanner.plan(
                typing: "new",
                terminatedBy: .none,
                at: .init(location: Self.second, verse: 0),
                in: score,
            )
            try Self.apply(plan, to: &score)

            let written = LyricInputPlanner.lyric(
                at: .init(location: Self.second, verse: 0),
                in: score,
            )
            #expect(written?.syllabic == expected)
        }
    }

    @Test("A hyphen then men produces begin and end")
    func twoSyllableWord() throws {
        var score = EditingFixtures.twoConsecutiveC4Chords()
        let firstPlan = LyricInputPlanner.plan(
            typing: "A",
            terminatedBy: .syllable,
            at: .init(location: Self.first, verse: 0),
            in: score,
        )
        try Self.apply(firstPlan, to: &score)
        let secondCursor = try #require(firstPlan.next)
        let secondPlan = LyricInputPlanner.plan(
            typing: "men",
            terminatedBy: .none,
            at: secondCursor,
            in: score,
        )
        try Self.apply(secondPlan, to: &score)

        #expect(Self.lyric(at: Self.first, in: score)?.syllabic == .begin)
        #expect(Self.lyric(at: Self.second, in: score)?.syllabic == .end)
    }

    @Test("three hyphenated syllables produce begin middle end")
    func threeSyllableWord() throws {
        var score = EditingFixtures.twoConsecutiveC4Chords()
        let third = Self.id(element: 3)
        Self.replaceWithChord(at: third, in: &score)
        var cursor = LyricInputPlanner.Cursor(location: Self.first, verse: 0)

        for text in ["ev", "er"] {
            let plan = LyricInputPlanner.plan(typing: text, terminatedBy: .syllable, at: cursor, in: score)
            try Self.apply(plan, to: &score)
            cursor = try #require(plan.next)
        }
        let finalPlan = LyricInputPlanner.plan(typing: "more", terminatedBy: .none, at: cursor, in: score)
        try Self.apply(finalPlan, to: &score)

        #expect(Self.lyric(at: Self.first, in: score)?.syllabic == .begin)
        #expect(Self.lyric(at: Self.second, in: score)?.syllabic == .middle)
        #expect(Self.lyric(at: third, in: score)?.syllabic == .end)
    }

    @Test("a melisma crossing a 4/4 bar line spans 960 ticks")
    func crossBarMelisma() throws {
        var score = EditingFixtures.c4AcrossBarline()
        let from = Self.id(measure: 0, element: 4)
        let skipped = Self.id(measure: 1, element: 0)
        let cursor = Self.id(measure: 1, element: 1)
        Self.replaceWithChord(at: cursor, in: &score)
        Self.setLyrics([Lyric(text: "hold", syllabic: .single)], at: from, in: &score)

        let plan = LyricInputPlanner.plan(
            typing: "",
            terminatedBy: .melisma,
            at: .init(location: cursor, verse: 0),
            in: score,
        )
        try Self.apply(plan, to: &score)

        #expect(Self.lyric(at: from, in: score)?.ticks == 960)
        #expect(Self.lyric(at: skipped, in: score) == nil)
    }

    @Test("planning at the staff's last chord returns no next cursor")
    func lastChordEndsSession() {
        let score = EditingFixtures.c4AcrossBarline()
        let last = Self.id(measure: 1, element: 0)

        let plan = LyricInputPlanner.plan(
            typing: "last",
            terminatedBy: .word,
            at: .init(location: last, verse: 3),
            in: score,
        )

        #expect(plan.next == nil)
    }

    @Test("from search skips chords without a syllable")
    func fromSearchSkipsEmptyChords() throws {
        var score = EditingFixtures.chordAtIndex1()
        let cursor = Self.id(element: 3)
        Self.replaceWithChord(at: Self.second, in: &score)
        Self.replaceWithChord(at: cursor, in: &score)
        Self.replaceWithChord(at: Self.id(element: 4), in: &score)
        Self.setLyrics([Lyric(text: "prior", syllabic: .end, ticks: 99)], at: Self.first, in: &score)

        let plan = LyricInputPlanner.plan(
            typing: "",
            terminatedBy: .syllable,
            at: .init(location: cursor, verse: 0),
            in: score,
        )
        try Self.apply(plan, to: &score)

        #expect(Self.lyric(at: Self.first, in: score)?.syllabic == .middle)
        #expect(Self.lyric(at: Self.first, in: score)?.ticks == 0)
        #expect(Self.lyric(at: Self.second, in: score) == nil)
        #expect(Self.lyric(at: cursor, in: score) == nil)
    }

    @Test("Space repairs the preceding syllable when the cursor chord has none")
    func wordSearchesBackwardForFrom() throws {
        var score = EditingFixtures.twoConsecutiveC4Chords()
        Self.setLyrics(
            [Lyric(text: "prior", syllabic: .begin, ticks: 480)],
            at: Self.first,
            in: &score,
        )

        let plan = LyricInputPlanner.plan(
            typing: "",
            terminatedBy: .word,
            at: .init(location: Self.second, verse: 0),
            in: score,
        )
        try Self.apply(plan, to: &score)

        #expect(Self.lyric(at: Self.first, in: score)?.syllabic == .single)
        #expect(Self.lyric(at: Self.first, in: score)?.ticks == 0)
        #expect(Self.lyric(at: Self.second, in: score) == nil)
    }

    @Test("empty verse padding behaves exactly like no lyric")
    func emptyPaddingIsNoSyllable() throws {
        var padded = EditingFixtures.twoConsecutiveC4Chords()
        var absent = EditingFixtures.twoConsecutiveC4Chords()
        Self.setLyrics(
            [Lyric(text: "", verse: 0), Lyric(text: "la", verse: 1)],
            at: Self.second,
            in: &padded,
        )
        Self.setLyrics([Lyric(text: "prior", syllabic: .single)], at: Self.first, in: &padded)
        Self.setLyrics([Lyric(text: "prior", syllabic: .single)], at: Self.first, in: &absent)
        let cursor = LyricInputPlanner.Cursor(location: Self.second, verse: 0)

        #expect(LyricInputPlanner.lyric(at: cursor, in: padded) == nil)
        #expect(LyricInputPlanner.lyric(at: cursor, in: absent) == nil)

        let paddedAdvance = LyricInputPlanner.plan(
            typing: "prior",
            terminatedBy: .syllable,
            at: .init(location: Self.first, verse: 0),
            in: padded,
        )
        let absentAdvance = LyricInputPlanner.plan(
            typing: "prior",
            terminatedBy: .syllable,
            at: .init(location: Self.first, verse: 0),
            in: absent,
        )
        #expect(paddedAdvance.command.map { $0 is SetLyric } == true)
        #expect(absentAdvance.command.map { $0 is SetLyric } == true)
        try Self.apply(paddedAdvance, to: &padded)
        try Self.apply(absentAdvance, to: &absent)
        #expect(LyricInputPlanner.lyric(at: cursor, in: padded) == nil)
        #expect(LyricInputPlanner.lyric(at: cursor, in: absent) == nil)

        let paddedPlan = LyricInputPlanner.plan(
            typing: "new",
            terminatedBy: .none,
            at: cursor,
            in: padded,
        )
        let absentPlan = LyricInputPlanner.plan(
            typing: "new",
            terminatedBy: .none,
            at: cursor,
            in: absent,
        )
        try Self.apply(paddedPlan, to: &padded)
        try Self.apply(absentPlan, to: &absent)

        #expect(Self.lyric(at: Self.second, in: padded)?.syllabic == .end)
        #expect(Self.lyric(at: Self.second, in: absent)?.syllabic == .end)
        #expect(Self.lyric(at: Self.second, in: padded)?.text == Self.lyric(at: Self.second, in: absent)?.text)
    }

    @Test("cursor helpers preserve verse and enforce the verse-zero floor")
    func cursorHelpers() {
        let score = EditingFixtures.c4AcrossBarline()
        let current = LyricInputPlanner.Cursor(location: Self.id(measure: 1, element: 0), verse: 2)

        #expect(LyricInputPlanner.previousCursor(from: current, in: score) == .init(
            location: Self.id(measure: 0, element: 4),
            verse: 2,
        ))
        #expect(LyricInputPlanner.verseCursor(.previous, from: current)?.verse == 1)
        #expect(LyricInputPlanner.verseCursor(.next, from: current)?.verse == 3)
        #expect(LyricInputPlanner.verseCursor(
            .previous,
            from: .init(location: Self.first, verse: 0),
        ) == nil)
    }

    @Test("applying a pending lyric plan to a preview copy leaves the committed score unchanged")
    func previewCopyDoesNotMutateCommittedScore() throws {
        let committed = EditingFixtures.twoConsecutiveC4Chords()
        var preview = committed
        let plan = LyricInputPlanner.plan(
            typing: "live",
            terminatedBy: .none,
            at: .init(location: Self.first, verse: 0),
            in: committed,
        )

        try Self.apply(plan, to: &preview)

        #expect(Self.lyric(at: Self.first, in: committed) == nil)
        #expect(Self.lyric(at: Self.first, in: preview)?.text == "live")
        #expect(preview != committed)
    }

    private func assertTransitionTable(
        terminator: LyricInputPlanner.Terminator,
        expectedFrom: [Syllabic],
        expectedTo: [Syllabic],
        expectedFromTicks: Int,
    ) throws {
        for (fromIndex, fromSyllabic) in Self.syllabics.enumerated() {
            for (toIndex, toSyllabic) in Self.syllabics.enumerated() {
                var score = EditingFixtures.twoConsecutiveC4Chords()
                Self.setLyrics(
                    [Lyric(text: "from", syllabic: fromSyllabic, ticks: 96)],
                    at: Self.first,
                    in: &score,
                )
                Self.setLyrics(
                    [Lyric(text: "to", syllabic: toSyllabic, ticks: 72)],
                    at: Self.second,
                    in: &score,
                )

                let plan = LyricInputPlanner.plan(
                    typing: "from",
                    terminatedBy: terminator,
                    at: .init(location: Self.first, verse: 0),
                    in: score,
                )
                try Self.apply(plan, to: &score)

                #expect(Self.lyric(at: Self.first, in: score)?.syllabic == expectedFrom[fromIndex])
                #expect(Self.lyric(at: Self.first, in: score)?.ticks == expectedFromTicks)
                #expect(Self.lyric(at: Self.second, in: score)?.syllabic == expectedTo[toIndex])
                #expect(Self.lyric(at: Self.second, in: score)?.ticks == 72)
            }
        }
    }

    private static func id(measure: Int = 0, element: Int) -> VoiceElementID {
        VoiceElementID(
            staff: EditingFixtures.staff0,
            measureIndex: measure,
            voiceIndex: 0,
            elementIndex: element,
        )
    }

    private static func lyric(at id: VoiceElementID, in score: Score) -> Lyric? {
        LyricInputPlanner.lyric(at: .init(location: id, verse: 0), in: score)
    }

    private static func setLyrics(_ lyrics: [Lyric], at id: VoiceElementID, in score: inout Score) {
        guard case var .chord(chord) = score[id] else {
            Issue.record("expected chord")
            return
        }
        chord.lyrics = lyrics
        score[id] = .chord(chord)
    }

    private static func replaceWithChord(at id: VoiceElementID, in score: inout Score) {
        score[id] = .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)]))
    }

    private static func apply(_ plan: LyricInputPlanner.Plan, to score: inout Score) throws {
        if let command = plan.command {
            _ = try command.apply(to: &score)
        }
    }
}
