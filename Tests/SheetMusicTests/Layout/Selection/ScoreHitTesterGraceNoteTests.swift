#if os(macOS)
    import CoreGraphics
    import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    /// A grace notehead as a hit and caret target: the layout names each grace head, the notehead rung reports it
    /// instead of the chord beside it, and the caret geometry frames its own column.
    @Suite("ScoreHitTester — grace noteheads")
    struct ScoreHitTesterGraceNoteTests {
        private let _installApple = TestSupport.installApple

        private static let staff0 = StaffAddress(partIndex: 0, staffIndexInPart: 0)

        /// B4 with a B4 acciaccatura before it, D5 with a D5 after-grace, then a half rest. Each grace shares its
        /// parent's pitch, so the two heads sit on one line and only horizontal distance separates them.
        private static func score() -> Score {
            let voice = Voice(elements: [
                .clef(Clef(concertClefType: "G")),
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                .chord(Chord(
                    duration: .quarter, notes: [Note(pitch: 71, tpc: 19)],
                    graceNotesBefore: [GraceChord(
                        graceType: .acciaccatura, duration: .eighth, notes: [Note(pitch: 71, tpc: 19)],
                    )],
                    graceNotesAfter: [],
                )),
                .chord(Chord(
                    duration: .quarter, notes: [Note(pitch: 74, tpc: 16)],
                    graceNotesBefore: [],
                    graceNotesAfter: [GraceChord(
                        graceType: .grace8after, duration: .eighth, notes: [Note(pitch: 74, tpc: 16)],
                    )],
                )),
                .rest(duration: .half),
            ])
            return Score(division: 480, parts: [Part(
                id: "1", instrument: Instrument(id: "x"),
                staves: [Staff(measures: [Measure(voices: [voice])])],
            )])
        }

        private static func parent(_ element: Int) -> VoiceElementID {
            VoiceElementID(staff: staff0, measureIndex: 0, voiceIndex: 0, elementIndex: element)
        }

        private static let before = GraceNoteID(
            parent: parent(2), side: .before, graceIndex: 0, noteIndexInGraceChord: 0,
        )
        private static let after = GraceNoteID(
            parent: parent(3), side: .after, graceIndex: 0, noteIndexInGraceChord: 0,
        )

        private static func noteID(_ element: Int) -> NoteID {
            NoteID(staff: staff0, measureIndex: 0, voiceIndex: 0, elementIndex: element, noteIndexInChord: 0)
        }

        private static func layout(_ score: Score) -> LayoutDocument {
            LayoutEngine.layout(score: score, options: ScoreViewOptions(), availableWidth: 1200)
        }

        private struct Head {
            let note: LayoutChordNote
            /// The head's origin in document coordinates — where `ScoreHitTester` centers its reach.
            let at: CGPoint
            /// Drawn by a `.graceChord` element rather than a `.chord`.
            let grace: Bool
        }

        /// Every laid-out head, chord and grace alike.
        private static func heads(in document: LayoutDocument) -> [Head] {
            var out: [Head] = []
            for system in document.systems {
                for measure in system.measures {
                    let baseX = system.origin.x + measure.origin.x
                    let baseY = system.origin.y + measure.origin.y
                    for element in measure.elements {
                        var notes: [LayoutChordNote] = []
                        var grace = false
                        if case let .chord(chordNotes, _, _, _, _, _, _, _, _, _, _) = element {
                            notes = chordNotes
                        } else if case let .graceChord(graceNotes, _, _, _, _, _, _, _) = element {
                            notes = graceNotes
                            grace = true
                        }
                        for note in notes {
                            let at = CGPoint(x: baseX + note.origin.x, y: baseY + note.origin.y)
                            out.append(Head(note: note, at: at, grace: grace))
                        }
                    }
                }
            }
            return out
        }

        private static func head(of item: ScoreItemID, in document: LayoutDocument) throws -> CGPoint {
            try #require(heads(in: document).first { $0.note.selectionItem == item }).at
        }

        private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
            ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
        }

        @Test("Every grace head carries its grace identity; every chord head selects as its own note")
        func layoutNamesGraceHeads() {
            let heads = Self.heads(in: Self.layout(Self.score()))
            let graceItems = Set(heads.filter(\.grace).map(\.note.selectionItem))
            #expect(graceItems == [.graceNote(Self.before), .graceNote(Self.after)])
            for head in heads where !head.grace {
                #expect(head.note.graceNoteID == nil)
                #expect(head.note.selectionItem == .note(head.note.noteID))
            }
        }

        @Test("A click on a grace head, even on its side facing the parent, hits the grace note")
        func graceHeadWinsOverParent() throws {
            guard #available(macOS 15.0, *) else { return }
            let score = Self.score()
            let document = Self.layout(score)
            let tester = ScoreHitTester(document: document)
            let sp = document.metrics.sp
            let cases: [(grace: GraceNoteID, parent: NoteID)] = [
                (Self.before, Self.noteID(2)), (Self.after, Self.noteID(3)),
            ]
            for (grace, parent) in cases {
                let graceHead = try Self.head(of: .graceNote(grace), in: document)
                let parentHead = try Self.head(of: .note(parent), in: document)
                #expect(tester.hitTest(at: graceHead) == .graceNote(grace))
                #expect(tester.itemID(at: graceHead) == .graceNote(grace))
                #expect(document.editingHitTest(at: graceHead, activeVoice: 0) == .graceNote(grace))

                // 0.4 sp from the grace head's center toward its parent: still inside the grace head's own reach,
                // and — the case first-match got wrong — inside the parent head's reach too.
                let towardParent: CGFloat = parentHead.x > graceHead.x ? 1 : -1
                let inner = CGPoint(x: graceHead.x + towardParent * sp * 0.4, y: graceHead.y)
                try #require(Self.distance(inner, parentHead) <= sp * 1.2, "fixture no longer overlaps the reaches")
                #expect(tester.hitTest(at: inner) == .graceNote(grace))
                #expect(tester.hitTest(at: inner)?.selectableItem == .graceNote(grace))

                // The control: the parent's own head still selects the parent.
                #expect(tester.hitTest(at: parentHead) == .note(parent))
                #expect(document.editingHitTest(at: parentHead, activeVoice: 0) == .note(parent))
            }
        }

        @Test("A grace target maps to its selection item and to no text or element identity")
        func targetVocabulary() {
            let target = ScoreHitTarget.graceNote(Self.after)
            #expect(target.selectableItem == .graceNote(Self.after))
            #expect(target.textID == nil)
            #expect(target.elementID == nil)
        }

        @Test("A selected grace note carets on its own column, inside its parent's staff band")
        func caretFramesGraceColumn() throws {
            let score = Self.score()
            let document = Self.layout(score)
            let sp = document.metrics.sp
            for (grace, parent) in [(Self.before, Self.noteID(2)), (Self.after, Self.noteID(3))] {
                let graceRect = try #require(document.editingCaretRect(for: .graceNote(grace), in: score))
                let parentRect = try #require(document.editingCaretRect(for: .note(parent), in: score))
                let graceHead = try Self.head(of: .graceNote(grace), in: document)
                #expect(abs(graceRect.midX - graceHead.x) < sp * 0.5)
                #expect(abs(graceRect.midX - parentRect.midX) > sp)
                #expect(graceRect.minY == parentRect.minY)
                #expect(graceRect.height == parentRect.height)
            }
        }
    }
#endif
