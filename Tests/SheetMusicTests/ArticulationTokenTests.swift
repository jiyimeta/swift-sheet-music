@testable import SheetMusicCore
@testable import SheetMusicMSCX
import Testing

/// The MSCX articulation token table, now in Core: `ChordArticulation.Kind.mscxToken` and its inverse. The decode
/// and encode paths call it, so this suite is what pins that the move changed no string.
@Suite("ChordArticulation.Kind mscx tokens")
struct ArticulationTokenTests {
    /// Every modeled kind and the MuseScore SymId base it spells — MuseScore's Articulations palette, default and
    /// master lists (`PaletteCreator::newArticulationsPalette`).
    private static let known: [(ChordArticulation.Kind, String)] = [
        (.staccato, "articStaccato"), (.staccatissimo, "articStaccatissimo"), (.tenuto, "articTenuto"),
        (.accent, "articAccent"), (.marcato, "articMarcato"),
        (.accentStaccato, "articAccentStaccato"), (.marcatoStaccato, "articMarcatoStaccato"),
        (.tenutoStaccato, "articTenutoStaccato"), (.tenutoAccent, "articTenutoAccent"),
        (.marcatoTenuto, "articMarcatoTenuto"), (.staccatissimoStroke, "articStaccatissimoStroke"),
        (.staccatissimoWedge, "articStaccatissimoWedge"), (.stress, "articStress"), (.unstress, "articUnstress"),
        (.softAccent, "articSoftAccent"), (.softAccentStaccato, "articSoftAccentStaccato"),
        (.softAccentTenuto, "articSoftAccentTenuto"), (.softAccentTenutoStaccato, "articSoftAccentTenutoStaccato"),
        (.muteOpen, "brassMuteOpen"), (.muteClosed, "brassMuteClosed"), (.harmonic, "stringsHarmonic"),
        (.upBow, "stringsUpBow"), (.downBow, "stringsDownBow"), (.laissezVibrer, "articLaissezVibrer"),
    ]

    @Test("each known kind spells its MuseScore SymId base, and reads back", arguments: known)
    func tokens(kind: ChordArticulation.Kind, token: String) {
        #expect(kind.mscxToken == token)
        #expect(ChordArticulation.Kind(mscxToken: token) == kind)
    }

    @Test("the table names every modeled kind once")
    func tableCoversEveryModeledKind() {
        #expect(Self.known.map(\.0) == ChordArticulation.Kind.modeled)
    }

    @Test("an unknown token has no known kind, and an unknown kind spells its raw string back")
    func unknown() {
        #expect(ChordArticulation.Kind(mscxToken: "handbellsMartellato") == nil)
        #expect(
            ChordArticulation.Kind.unknown(subtype: "handbellsMartellato").mscxToken == "handbellsMartellato",
        )
    }

    @Test("the decoder still strips the anchor and keeps the FULL string for an unknown", arguments: [
        ("articStaccatoAbove", ChordArticulation(kind: .staccato, anchor: .above)),
        ("articTenutoBelow", ChordArticulation(kind: .tenuto, anchor: .below)),
        ("articTenutoStaccatoBelow", ChordArticulation(kind: .tenutoStaccato, anchor: .below)),
        ("articStressBelow", ChordArticulation(kind: .stress, anchor: .below)),
        ("articSoftAccentTenutoStaccatoAbove", ChordArticulation(kind: .softAccentTenutoStaccato, anchor: .above)),
        ("stringsUpBow", ChordArticulation(kind: .upBow, anchor: nil)),
        ("brassMuteClosed", ChordArticulation(kind: .muteClosed, anchor: nil)),
        ("articLaissezVibrerBelow", ChordArticulation(kind: .laissezVibrer, anchor: .below)),
        ("articAccent", ChordArticulation(kind: .accent, anchor: nil)),
        ("handbellsMartellato", ChordArticulation(kind: .unknown(subtype: "handbellsMartellato"))),
    ])
    func decodeIsUnchanged(subtype: String, expected: ChordArticulation) {
        #expect(ChordArticulation.fromSubtypeXML(subtype) == expected)
    }

    @Test("encode is the inverse for every known kind and both anchors, and verbatim for an unknown")
    func encodeIsUnchanged() {
        for (kind, token) in Self.known where kind.hasPlacementVariants {
            #expect(ChordArticulation(kind: kind, anchor: .above).subtypeXML() == token + "Above")
            #expect(ChordArticulation(kind: kind, anchor: .below).subtypeXML() == token + "Below")
            #expect(ChordArticulation(kind: kind, anchor: nil).subtypeXML() == token + "Above")
        }
        #expect(ChordArticulation(kind: .unknown(subtype: "x"), anchor: .below).subtypeXML() == "x")
    }

    /// The brass mutes, the harmonic and the bow marks are one SymId each — `stringsUpBow`, not
    /// `stringsUpBowAbove`, which MuseScore would not read — so they go out bare whatever the anchor says.
    @Test("a kind with no Above / Below pair writes its token bare")
    func singleFormKindsWriteBare() {
        let bare: [ChordArticulation.Kind] = [.muteOpen, .muteClosed, .harmonic, .upBow, .downBow]
        #expect(Self.known.filter { !$0.0.hasPlacementVariants }.map(\.0) == bare)
        for kind in bare {
            #expect(ChordArticulation(kind: kind, anchor: nil).subtypeXML() == kind.mscxToken)
            #expect(ChordArticulation(kind: kind, anchor: .below).subtypeXML() == kind.mscxToken)
        }
    }

    /// MuseScore's `ARPEGGIO_TYPES` is `0 NORMAL, 1 UP, 2 DOWN, 3 BRACKET, 4 UP_STRAIGHT, 5 DOWN_STRAIGHT`
    /// (`typesconv.cpp:2558-2565`). Only 2 and 5 spread downwards. The tree's one arpeggio fixture carries
    /// subtypes 0, 1 and 2 only, so this predicate is the only place 3…5 is checked at all.
    @Test("arpeggio subtypes 2 and 5 descend; 0, 1, 3 and 4 ascend", arguments: [
        (0, true), (1, true), (2, false), (3, true), (4, true), (5, false),
    ] as [(Int, Bool)])
    func arpeggioDirection(subtype: Int, ascending: Bool) {
        #expect(Arpeggio(subtype: subtype).isAscending == ascending)
    }
}
