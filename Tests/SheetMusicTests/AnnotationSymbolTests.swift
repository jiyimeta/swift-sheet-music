import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import Testing

private func annotationSymbolScore() throws -> Score {
    try MSCXParser.parse(MSCXFixtureLoader.mscxData("annotation-symbol"))
}

private func annotationSymbolFingerprint(_ element: VoiceElement) -> UInt64 {
    var hasher = FNV1a()
    hasher.combine(element)
    return hasher.value
}

@Suite("Annotation symbol MSCX decoding")
struct AnnotationSymbolDecodeTests {
    @Test func voiceLevelSymbolDecodesInItsStreamPosition() throws {
        let score = try annotationSymbolScore()
        let elements = score.parts[0].staves[0].measures[0].voices[0].elements
        try #require(elements.count == 3)
        guard case .chord = elements[0],
              case let .symbol(symbol) = elements[1],
              case .chord = elements[2]
        else {
            Issue.record("expected chord, annotation symbol, chord")
            return
        }
        #expect(symbol.name == "ornamentTrill")
        #expect(symbol.scoreFont == "Bravura")
        #expect(symbol.size == 1.5)
        #expect(symbol.angle == -12.25)
        #expect(symbol.elementProperties == .default)
        #expect(symbol.preservedMarkup.isEmpty)
    }

    @Test func noteAttachedSymbolDoesNotBecomeAVoiceElement() throws {
        let score = try annotationSymbolScore()
        let elements = score.parts[0].staves[0].measures[1].voices[0].elements
        try #require(elements.count == 1)
        guard case let .chord(chord) = elements[0] else {
            Issue.record("expected a chord carrying a note-attached symbol")
            return
        }
        let note = try #require(chord.notes.first)
        #expect(note.symbols.map(\.name) == ["futureNoteGlyphFromMSC6"])
        let hasVoiceSymbol = elements.contains { element in
            if case .symbol = element { return true }
            return false
        }
        #expect(!hasVoiceSymbol)
    }

    @Test func unknownNameSurvivesVerbatim() throws {
        let score = try annotationSymbolScore()
        let elements = score.parts[0].staves[0].measures[2].voices[0].elements
        guard case let .symbol(symbol)? = elements.first else {
            Issue.record("expected an annotation symbol before the chord")
            return
        }
        #expect(symbol.name == "futureSegmentGlyphFromMSC6")
    }

    @Test func nestedUnmodeledChildIsPreservedAndReencoded() throws {
        let score = try annotationSymbolScore()
        let elements = score.parts[0].staves[0].measures[2].voices[0].elements
        guard case let .symbol(symbol)? = elements.first else {
            Issue.record("expected an annotation symbol before the chord")
            return
        }
        #expect(symbol.preservedMarkup == [
            PreservedXML(name: "Symbol", children: [
                PreservedXML(name: "name", text: "ornamentTurn"),
            ]),
        ])

        let reparsed = try MSCXParser.parse(MSCXEncoder.encode(score))
        let reparsedElements = reparsed.parts[0].staves[0].measures[2].voices[0].elements
        guard case let .symbol(reparsedSymbol)? = reparsedElements.first else {
            Issue.record("expected the reencoded annotation symbol before the chord")
            return
        }
        #expect(reparsedSymbol.preservedMarkup == symbol.preservedMarkup)
    }
}

@Suite("Annotation symbol parity")
struct AnnotationSymbolParityTests {
    /// The fixture is hand-written and minimal, so it is not in the encoder's
    /// canonical form — encoding fills in `<Style>`, `<StaffType>` and the
    /// `id` attributes MuseScore would have written. Asserting byte equality
    /// against the file on disk would therefore be testing how the skeleton
    /// was typed, and it would break on any future canonicalization that has
    /// nothing to do with symbols. The two properties that are actually about
    /// this slice are asserted instead, matching what `FiguredBassTests` does
    /// for its own fixture. Whole-corpus byte fidelity is
    /// `MSCXPreservationGateTests`, not this file.
    @Test func fixtureSurvivesEncodeAndReparse() throws {
        let score = try annotationSymbolScore()
        let reparsed = try MSCXParser.parse(MSCXEncoder.encode(score))
        #expect(reparsed == score)
    }

    /// Encoding is idempotent: the second pass changes nothing. This is the
    /// byte-level statement the fixture can actually support, and it is the
    /// one that would catch a symbol being written in a shape the decoder
    /// reads back differently.
    @Test func encodingTheAnnotationSymbolIsIdempotent() throws {
        let once = try MSCXEncoder.encode(annotationSymbolScore())
        let twice = try MSCXEncoder.encode(MSCXParser.parse(once))
        #expect(once == twice)
    }

    @Test func fingerprintIncludesTheSymbolPayload() {
        let trill = annotationSymbolFingerprint(.symbol(EngravingSymbol(name: "ornamentTrill")))
        let turn = annotationSymbolFingerprint(.symbol(EngravingSymbol(name: "ornamentTurn")))
        #expect(trill != turn)
    }

    @Test func symbolParticipatesInTheAdjacentAnnotationRun() {
        let symbol = VoiceElement.symbol(EngravingSymbol(name: "ornamentTrill"))
        #expect(AdjacentElementSlot.isAnnotation(symbol))
    }

    @Test func visibilityReadsAndWritesTheSymbolProperties() throws {
        var score = try annotationSymbolScore()
        let location = VoiceElementID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: 0,
            voiceIndex: 0,
            elementIndex: 1,
        )
        #expect(SetElementVisible.current(at: location, in: score) == true)

        _ = try SetElementVisible(at: location, visible: false).apply(to: &score)
        guard case let .symbol(symbol)? = score[location] else {
            Issue.record("expected the annotation symbol at its original position")
            return
        }
        #expect(!symbol.visible)
        #expect(SetElementVisible.current(at: location, in: score) == false)
    }

    @Test func strippingPreservedMarkupClearsTheAnnotationSymbolBag() throws {
        let stripped = try annotationSymbolScore().strippingPreservedMarkup()
        let elements = stripped.parts[0].staves[0].measures[2].voices[0].elements
        guard case let .symbol(symbol)? = elements.first else {
            Issue.record("expected an annotation symbol before the chord")
            return
        }
        #expect(symbol.name == "futureSegmentGlyphFromMSC6")
        #expect(symbol.preservedMarkup.isEmpty)
    }
}
