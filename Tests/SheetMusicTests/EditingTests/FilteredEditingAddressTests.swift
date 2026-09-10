import SheetMusicCore
import SheetMusicFoundation
import SheetMusicLayout
import Testing

@Suite("Filtered editing address boundaries")
struct FilteredEditingAddressTests {
    private let hidden: Set<StaffAddress> = [
        StaffAddress(partIndex: 0, staffIndexInPart: 0),
        StaffAddress(partIndex: 1, staffIndexInPart: 0),
        StaffAddress(partIndex: 1, staffIndexInPart: 2),
    ]
    private let displayed = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    private let original = StaffAddress(partIndex: 1, staffIndexInPart: 1)

    private func fixture() -> Score {
        let staff = Staff(measures: [Measure(voices: [Voice(elements: [
            .clef(Clef(concertClefType: "G")),
            .chord(Chord(duration: .whole, notes: [Note(pitch: 60, tpc: 14)])),
        ])])])
        return ScoreEditor(score: Score(division: 480, parts: [
            Part(id: "hidden", instrument: Instrument(id: "a"), staves: [staff]),
            Part(id: "mixed", instrument: Instrument(id: "b"), staves: [staff, staff, staff, staff]),
        ])).score
    }

    private func anchor(_ staff: StaffAddress, element: Int = 1) -> VoiceElementID {
        VoiceElementID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: element)
    }

    @Test("Default and explicit clefs re-stamp after hidden leading staff and part", arguments: [false, true])
    func clefRoundTrip(explicit: Bool) throws {
        let full = fixture()
        let filteredClef: ClefAnchor = explicit ? .explicit(anchor(displayed, element: 0)) : .staffDefault(displayed)
        let fullClef: ClefAnchor = explicit ? .explicit(anchor(original, element: 0)) : .staffDefault(original)
        #expect(full.engineCursorForFilteredTap(
            .item(.clef(filteredClef)), hiddenStaves: hidden,
        ) == .item(.clef(fullClef)))
        #expect(full.translateCursorForHiddenStaves(
            .item(.clef(fullClef)), hiddenStaves: hidden,
        ) == .item(.clef(filteredClef)))
        let map = ScoreEditingAddressMap(score: full, hiddenStaves: hidden)
        #expect(map.fullItem(forDisplayed: .clef(filteredClef)) == .clef(fullClef))
        #expect(map.displayedItem(forFull: .clef(fullClef)) == .clef(filteredClef))
        var edited = full
        if explicit {
            _ = try ReplaceVoiceElement(at: anchor(original, element: 0), with: .clef(Clef(concertClefType: "F")))
                .apply(to: &edited)
        } else {
            _ = try SetStaffDefaultClef(staff: original, newRawType: "F").apply(to: &edited)
        }
        for staff in hidden {
            #expect(edited[staff] == full[staff])
        }
        #expect(edited[original] != full[original])
    }

    @Test("Every staff-addressed editor identity round-trips without changing its element indices")
    func identityRoundTrips() {
        let map = ScoreEditingAddressMap(score: fixture(), hiddenStaves: hidden)
        func items(_ staff: StaffAddress) -> [ScoreItemID] {
            let location = anchor(staff)
            let note = NoteID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 1, noteIndexInChord: 0)
            return [
                .note(note),
                .rest(RestID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 1)),
                .tuplet(TupletID(staff: staff, measureIndex: 0, voiceIndex: 0, startElementIndex: 1)),
                .text(.lyric(anchor: location, verse: 2)),
                .text(.staffText(anchor: location, style: .staffText)),
                .text(.harmony(anchor: location)),
                .element(.tie(start: note, end: note)),
            ]
        }
        for (visible, full) in zip(items(displayed), items(original)) {
            #expect(map.fullItem(forDisplayed: visible) == full)
            #expect(map.displayedItem(forFull: full) == visible)
        }
    }

    @Test("Range command destinations skip hidden middle staves and preserve their music")
    func rangeDestinations() throws {
        let full = fixture()
        let map = ScoreEditingAddressMap(score: full, hiddenStaves: hidden)
        let destinations = [original, StaffAddress(partIndex: 1, staffIndexInPart: 3)]
        #expect(map.visibleStaffAddresses == destinations)
        let filtered = full.filtered(hidingStaves: hidden)
        let resolved = try filtered.allStaves.map { staff in
            try #require(map.fullItem(forDisplayed: .text(.harmony(anchor: anchor(staff.address))))?.textID?.anchor)
        }
        #expect(resolved.map(\.staff) == destinations)
        var edited = full
        for location in resolved {
            _ = try DeleteVoiceElement(at: location).apply(to: &edited)
        }
        for staff in hidden {
            #expect(edited[staff] == full[staff])
        }
        for location in resolved {
            guard case let .chord(chord) = edited[location] else {
                Issue.record("Expected replacement rest")
                return
            }
            #expect(chord.notes.isEmpty)
        }
    }

    @Test("Hidden and stale staff addresses cannot leak playback fallback into editor selection")
    func rejectsHiddenAndStale() {
        let map = ScoreEditingAddressMap(score: fixture(), hiddenStaves: hidden)
        let missing = StaffAddress(partIndex: 99, staffIndexInPart: 0)
        #expect(map.fullItem(forDisplayed: .clef(.staffDefault(missing))) == nil)
        #expect(map.displayedItem(forFull: .clef(.staffDefault(missing))) == nil)
        for staff in hidden {
            #expect(map.displayedItem(forFull: .clef(.staffDefault(staff))) == nil)
            #expect(map.displayedItem(forFull: .text(.harmony(anchor: anchor(staff)))) == nil)
        }
        let bar = ScoreItemID.text(.rehearsalMark(measureIndex: 0))
        #expect(map.displayedItem(forFull: bar) == bar)
        #expect(map.fullItem(forDisplayed: bar) == bar)
        let allHidden = ScoreEditingAddressMap(score: fixture(), hiddenStaves: Set(fixture().allStaves.map(\.address)))
        #expect(allHidden.visibleStaffAddresses.isEmpty)
        #expect(allHidden.fullItem(forDisplayed: .clef(.staffDefault(displayed))) == nil)
    }

    @Test("Harmony previews preserve committed anchors through insertion and removal", arguments: [false, true])
    func harmonyPreviewOrdinals(removing: Bool) throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        _ = TestSupport.installFontMetrics
        var committed = fixture()
        let identity = try #require(committed.eid(at: anchor(original)))
        if removing {
            _ = try SetChordSymbol(at: anchor(original), name: "C").apply(to: &committed)
        }
        let committedAnchor = try #require(committed.position(of: identity))
        var preview = committed
        _ = try SetChordSymbol(at: committedAnchor, name: removing ? nil : "Am7").apply(to: &preview)
        let previewAnchor = try #require(preview.position(of: identity))
        #expect(previewAnchor.elementIndex == committedAnchor.elementIndex + (removing ? -1 : 1))
        let map = ScoreEditingAddressMap(score: committed, hiddenStaves: hidden, previewScore: preview)
        let fullItem = ScoreItemID.text(.harmony(anchor: committedAnchor))
        let displayedItem = try #require(map.displayedItem(forFull: fullItem))
        let displayedAnchor = try #require(displayedItem.textID?.anchor)
        #expect(displayedAnchor.staff == displayed)
        #expect(displayedAnchor.elementIndex == previewAnchor.elementIndex)
        #expect(map.fullItem(forDisplayed: displayedItem) == fullItem)
        let note = ScoreItemID.note(NoteID(
            staff: displayed, measureIndex: 0, voiceIndex: 0,
            elementIndex: displayedAnchor.elementIndex, noteIndexInChord: 0,
        ))
        #expect(map.fullItem(forDisplayed: note)?.elementIndex == committedAnchor.elementIndex)
        let document = LayoutEngine.layout(
            score: preview.filtered(hidingStaves: hidden), options: .init(), availableWidth: 800,
        )
        #expect(document.timedElementOrigin(at: displayedAnchor) != nil)
        if !removing {
            #expect(document.harmonyOrigin(at: displayedAnchor) != nil)
            let previewOnly = ScoreItemID.clef(.explicit(anchor(displayed)))
            #expect(map.fullItem(forDisplayed: previewOnly) == nil)
        }
        // Shared overlays perform this ordinal mapping even without Mac's staff filtering.
        let unfiltered = ScoreEditingAddressMap(score: committed, hiddenStaves: [], previewScore: preview)
        #expect(unfiltered.displayedItem(forFull: fullItem)?.textID?.anchor == previewAnchor)
    }

    @Test("Preview commit and cancel retain the selected note by identity; deletion clears it")
    func previewSelectionLifecycle() throws {
        var committed = fixture()
        let identity = try #require(committed.eid(at: anchor(original)))
        _ = try SetChordSymbol(at: anchor(original), name: "C").apply(to: &committed)
        let committedAnchor = try #require(committed.position(of: identity))
        var preview = committed
        _ = try SetChordSymbol(at: committedAnchor, name: "Dm7").apply(to: &preview)
        let previous = ScoreEditingAddressMap(score: committed, hiddenStaves: hidden, previewScore: preview)
        let fullNote = ScoreItemID.note(NoteID(
            staff: original, measureIndex: 0, voiceIndex: 0,
            elementIndex: committedAnchor.elementIndex, noteIndexInChord: 0,
        ))
        let selected = try #require(previous.displayedItem(forFull: fullNote))
        // Cancel returns to committed music; commit adopts a new copy of the pending command.
        for nextScore in [committed, preview] {
            let toCommitted = ScoreEditingAddressMap(
                score: nextScore, hiddenStaves: hidden, previewScore: preview,
            )
            let full = try #require(toCommitted.fullItem(forDisplayed: selected))
            let next = ScoreEditingAddressMap(score: nextScore, hiddenStaves: hidden)
            #expect(next.displayedItem(forFull: full) == selected)
            #expect(nextScore.eid(at: VoiceElementID(
                staff: full.staff, measureIndex: full.measureIndex,
                voiceIndex: full.voiceIndex, elementIndex: full.elementIndex,
            )) == identity)
        }
        var deleted = committed
        _ = try DeleteVoiceElement(at: committedAnchor).apply(to: &deleted)
        let toDeleted = ScoreEditingAddressMap(score: deleted, hiddenStaves: hidden, previewScore: preview)
        #expect(toDeleted.fullItem(forDisplayed: selected) == nil)
    }
}
