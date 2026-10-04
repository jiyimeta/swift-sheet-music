import Foundation
import SheetMusicCore
@testable import SheetMusicLayout
import Testing

/// The articulation kinds beyond the original seven: each one is drawn, with its own glyph, on the side MuseScore
/// puts it. Fixtures come from `LayoutArticulationTests`.
@Suite("LayoutEngine articulation kinds")
struct LayoutArticulationKindsTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    /// Every modeled kind reaches the page with the glyph pair SMuFL gives its SymId (`glyphnames.json`) — no kind
    /// falls through to "emit nothing", the way the louré, the bow marks and the rest of MuseScore's Articulations
    /// palette used to.
    @Test("Every modeled articulation kind is drawn, with its own SMuFL glyphs", arguments: [
        (ChordArticulation.Kind.tenutoAccent, 0xE4B4, 0xE4B5), (.marcatoTenuto, 0xE4BC, 0xE4BD),
        (.staccatissimoStroke, 0xE4AA, 0xE4AB), (.staccatissimoWedge, 0xE4A8, 0xE4A9),
        (.stress, 0xE4B6, 0xE4B7), (.unstress, 0xE4B8, 0xE4B9), (.softAccent, 0xED40, 0xED41),
        (.softAccentStaccato, 0xED42, 0xED43), (.softAccentTenuto, 0xED44, 0xED45),
        (.softAccentTenutoStaccato, 0xED46, 0xED47), (.muteOpen, 0xE5E7, 0xE5E7), (.muteClosed, 0xE5E5, 0xE5E5),
        (.harmonic, 0xE614, 0xE614), (.upBow, 0xE612, 0xE612), (.downBow, 0xE610, 0xE610),
        (.laissezVibrer, 0xE4BA, 0xE4BB),
    ] as [(ChordArticulation.Kind, UInt32, UInt32)])
    func everyKindIsDrawn(kind: ChordArticulation.Kind, above: UInt32, below: UInt32) throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let layoutKind = try #require(LayoutEngine.renderableArticulationKind(kind))
        #expect(ArticulationGlyph.codepoint(kind: layoutKind, isAbove: true) == above)
        #expect(ArticulationGlyph.codepoint(kind: layoutKind, isAbove: false) == below)
        let doc = LayoutArticulationTests.laidOut(LayoutArticulationTests.score(articulations: [.init(kind: kind)]))
        let (art, _) = try #require(LayoutArticulationTests.soleArtAndChord(doc))
        guard case let .articulation(drawn, _, _, _) = art else { Issue.record("not articulation"); return }
        #expect(drawn == layoutKind)
    }

    /// MuseScore anchors the brass mutes, the harmonic and the bow marks `TOP` (`AnchorGroup::OTHER`) and keeps the
    /// marcato range up (`articMarcatoAbove … articMarcatoTenutoBelow`), so a stem-up chord — whose other marks go
    /// below — still carries them above the staff.
    @Test("Technique marks and marcato-tenuto sit above a stem-up chord", arguments: [
        ChordArticulation.Kind.upBow, .downBow, .harmonic, .muteOpen, .muteClosed, .marcatoTenuto,
    ])
    func techniqueMarksSitAbove(kind: ChordArticulation.Kind) throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let doc = LayoutArticulationTests.laidOut(LayoutArticulationTests.score(
            pitch: 67, tpc: 15, // G4, below the middle line → stem up
            articulations: [.init(kind: kind)],
        ))
        let (art, _) = try #require(LayoutArticulationTests.soleArtAndChord(doc))
        guard case let .articulation(_, _, isAbove, _) = art else { Issue.record("not articulation"); return }
        #expect(isAbove)
    }

    /// MuseScore 4 counts only the staccato and tenuto categories as close-to-note (`layoutCloseToNote()`), and the
    /// staccatissimo is in neither, so it clears the staff like an accent. A staccato on the same note stays inside.
    @Test("A staccatissimo clears the staff where a staccato hugs the note", arguments: [
        (ChordArticulation.Kind.staccatissimo, false), (.staccato, true),
    ])
    func staccatissimoClearsTheStaff(kind: ChordArticulation.Kind, staysInside: Bool) throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let doc = LayoutArticulationTests.laidOut(LayoutArticulationTests.score(
            pitch: 72, tpc: 14, // C5, above the middle line → stem down → above, a staccato in the E5 space
            articulations: [.init(kind: kind)],
        ))
        let (art, _) = try #require(LayoutArticulationTests.soleArtAndChord(doc))
        guard case let .articulation(_, origin, isAbove, _) = art else { Issue.record("not articulation"); return }
        #expect(isAbove)
        let staffOriginY = try #require(doc.systems.first?.staffOrigins.first?.y)
        let staffTopY = staffOriginY + doc.metrics.staffHeight / 2 - doc.metrics.sp * 2
        #expect((origin.y > staffTopY) == staysInside, "origin \(origin.y), top line \(staffTopY)")
    }

    /// The louré (tenuto over staccato) drawn with its own SMuFL glyph and, being one of MuseScore's `isDouble()`
    /// articulations, pushed clear of the staff like the other combined forms rather than hugging the note. A bass
    /// part marked this way on every note used to show nothing at all: the subtype decoded as `.unknown`.
    @Test("Tenuto-staccato draws the louré glyph outside the staff")
    func tenutoStaccatoIsDrawn() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let doc = LayoutArticulationTests.laidOut(LayoutArticulationTests.score(
            pitch: 67, tpc: 15, // G4, below the middle line → stem up → below
            articulations: [.init(kind: .tenutoStaccato, anchor: .below)],
        ))
        let (art, _) = try #require(LayoutArticulationTests.soleArtAndChord(doc))
        guard case let .articulation(kind, origin, isAbove, _) = art
        else { Issue.record("not articulation"); return }
        #expect(kind == .tenutoStaccato)
        #expect(isAbove == false)
        #expect(ArticulationGlyph.codepoint(kind: kind, isAbove: isAbove) == 0xE4B3)
        #expect(ArticulationGlyph.codepoint(kind: kind, isAbove: true) == 0xE4B2)
        guard let system = doc.systems.first,
              let staffOriginY = system.staffOrigins.first?.y
        else { Issue.record("no staff origin"); return }
        let sp = doc.metrics.sp
        let staffBottomY = staffOriginY + doc.metrics.staffHeight / 2 + sp * 2
        #expect(origin.y >= staffBottomY + sp * 0.5 - 0.001)
    }
}
