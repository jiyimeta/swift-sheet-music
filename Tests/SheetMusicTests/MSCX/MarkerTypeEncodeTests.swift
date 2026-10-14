import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// A `<Marker>` written the way MuseScore writes one (`TWrite::write(Marker)`, `rw/write/twrite.cpp:2274-2282`) and
/// reads it: `<text>` then `<label>` then `<markerType>`, because `Marker::setMarkerType` fills an empty text and a
/// still-default label as the type is read (`dom/marker.cpp:86-106`) — written first, both were wiped by the empty
/// `<text>` and `<label>` after it, and MuseScore opened folino's markers blank and label-less (F3.5).
@Suite("MSCX marker writing")
struct MarkerTypeEncodeTests {
    private static func xml(_ marker: Marker, options: MSCXEncoderOptions = .init()) throws -> String {
        try #require(String(bytes: XMLTreeSerializer.serialize(marker.encode(options: options)), encoding: .utf8))
    }

    private static func offset(of tag: String, in xml: String) throws -> Int {
        let range = try #require(xml.range(of: tag))
        return xml.distance(from: xml.startIndex, to: range.lowerBound)
    }

    @Test("every kind writes MuseScore's type name, after its text and label (F3.4)")
    func namesAndOrder() throws {
        let cases: [(Marker.Kind, String)] = [
            (.segno, "segno"), (.varsegno, "varsegno"), (.coda, "codab"), (.varcoda, "varcoda"),
            (.codetta, "codetta"), (.fine, "fine"), (.toCoda, "coda"), (.toCodaSym, "codasym"), (.daCoda, "dacoda"),
            (.daDoubleCoda, "dadblcoda"), (.user, "user"), (.daCapo, "user"), (.dalSegno, "user"), (.other, "user"),
        ]
        for (kind, name) in cases {
            let xml = try Self.xml(Marker(kind: kind, text: "x"))
            #expect(xml.contains("<markerType>\(name)</markerType>"), "\(kind): \(xml)")
            let text = try Self.offset(of: "<text>", in: xml)
            let label = try Self.offset(of: "<label>", in: xml)
            let type = try Self.offset(of: "<markerType>", in: xml)
            #expect(text < label && label < type)
        }
    }

    /// Review Focus 1.
    @Test("a marker without text writes no <text> — MuseScore fills its default — and writes its default label (F3.5)")
    func textlessMarkerLeavesTextToMuseScore() throws {
        let coda = try Self.xml(Marker(kind: .coda))
        #expect(!coda.contains("<text"))
        #expect(coda.contains("<label>codab</label>"))
        #expect(coda.contains("<markerType>codab</markerType>"))
        let markup = PreservedTextMarkup(
            content: [.element(.init(name: "sym", content: [.characters("coda")]))], derivedText: "",
        )
        let symbolOnly = try Self.xml(Marker(kind: .coda, label: "codab", preservedTextMarkup: markup))
        #expect(symbolOnly.contains("<text><sym>coda</sym></text>"))
    }

    @Test("a D.C. marker, which MuseScore has no type for, writes its words as a Custom marker")
    func daCapoWritesItsWords() throws {
        let xml = try Self.xml(Marker(kind: .daCapo))
        #expect(xml.contains("<text>D.C.</text>") && xml.contains("<markerType>user</markerType>"))
    }

    /// Every kind saved and reopened: MuseScore's own types come back as themselves, this library's type-less ones as
    /// Custom markers with the same words.
    @Test("a saved marker reopens as its kind, in this library's 4.60 and 3.02 files alike")
    func roundTrip() throws {
        let kinds: [Marker.Kind] = [
            .segno, .varsegno, .coda, .varcoda, .codetta, .fine, .toCoda, .toCodaSym, .daCoda, .daDoubleCoda, .user,
            .daCapo, .dalSegno, .other,
        ]
        let measure = Measure(
            voices: [Voice(elements: [.chord(Chord(duration: .whole, notes: [Note(pitch: 60, tpc: 14)]))])],
            markers: kinds.map { Marker(kind: $0) },
        )
        let score = Score(division: 480, parts: [Part(
            id: "1", instrument: Instrument(id: "piano"), staves: [Staff(measures: [measure])],
        )])
        for target in [MSCXVersion.v4, .v3] {
            let data = try MSCXEncoder.encode(score, options: MSCXEncoderOptions(targetVersion: target))
            let reopened = try MSCXParser.parse(data)
            let markers = try #require(reopened.parts.first?.staves.first?.measures.first).markers
            #expect(markers.map(\.kind) == [
                .segno, .varsegno, .coda, .varcoda, .codetta, .fine, .toCoda, .toCodaSym, .daCoda, .daDoubleCoda,
                .user, .user, .user, .user,
            ])
            let printed = markers.map(\.displayedRichText.plainText)
            #expect(printed.suffix(4) == ["", "D.C.", "D.S.", ""])
        }
    }

    /// The three kinds MuseScore has no type for reload as Custom markers, and nothing a player or a reader meets
    /// changes: playback reads a marker only through its effective label and its side (`RepeatListBuilder`), both
    /// unchanged, and it prints the same words. The control — the same score without the markers — plays differently,
    /// so equal plans are evidence the markers were read, not ignored.
    @Test("D.C., D.S. and other markers reload as Custom markers that play and print the same")
    func legacyKindsPlayAndPrintTheSame() throws {
        func bar(_ markers: [Marker] = [], jumps: [Jump] = []) -> Measure {
            Measure(
                voices: [Voice(elements: [.chord(Chord(duration: .whole, notes: [Note(pitch: 60, tpc: 14)]))])],
                markers: markers, jumps: jumps,
            )
        }
        func score(_ bars: [Measure]) -> Score {
            Score(division: 480, parts: [Part(
                id: "1", instrument: Instrument(id: "piano", channels: [InstrumentChannel(program: 0)]),
                staves: [Staff(measures: bars)],
            )])
        }
        func plan(_ score: Score) -> [Int] {
            RepeatUnwinder.plan(navigation: ScoreNavigation(score: score)).map(\.measureIndex)
        }
        let legacy = [Marker(kind: .daCapo, label: "dc"), Marker(kind: .dalSegno), Marker(kind: .other, label: "x")]
        let jump = Jump(jumpTo: "dc", playUntil: "end", text: "D.S.")
        let original = score([bar(), bar(legacy), bar(), bar(jumps: [jump]), bar()])
        let reloaded = try MSCXParser.parse(MSCXEncoder.encode(original))
        let control = score([bar(), bar(), bar(), bar(jumps: [jump]), bar()])
        let markers = try #require(reloaded.parts.first?.staves.first?.measures[1]).markers
        #expect(markers.map(\.kind) == [.user, .user, .user])
        #expect(markers.map(\.effectiveLabel) == legacy.map(\.effectiveLabel))
        #expect(markers.map(\.isRightMarker) == legacy.map(\.isRightMarker))
        #expect(markers.map(\.displayedRichText.plainText) == legacy.map(\.displayedRichText.plainText))
        #expect(plan(reloaded) == plan(original))
        #expect(plan(original) != plan(control))
    }
}
