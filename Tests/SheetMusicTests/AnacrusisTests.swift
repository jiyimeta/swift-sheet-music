import Foundation
@testable import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicLayout
@testable import SheetMusicMSCX
import Testing

@Suite struct AnacrusisTests {
    @Test func measureCarriesActualLengthAndIrregular() {
        let pickup = Measure(
            voices: [],
            actualLength: Fraction(numerator: 1, denominator: 4),
            irregular: true
        )
        #expect(pickup.actualLength == Fraction(numerator: 1, denominator: 4))
        #expect(pickup.irregular == true)

        let normal = Measure(voices: [])
        #expect(normal.actualLength == nil)
        #expect(normal.irregular == false)

        // Equatable should pick up the new fields.
        #expect(pickup != Measure(voices: [], irregular: true))
        #expect(pickup != Measure(
            voices: [],
            actualLength: Fraction(numerator: 1, denominator: 4)
        ))
    }

    @Test func displayedMeasureNumberSkipsIrregular() {
        let staff = Staff(measures: [
            Measure(voices: [Voice(elements: [])], irregular: true),
            Measure(voices: [Voice(elements: [])]),
            Measure(voices: [Voice(elements: [])]),
        ])
        let part = Part(
            id: "1",
            instrument: Instrument(id: "x", longName: "Piano"),
            staves: [staff]
        )
        let score = Score(division: 480, parts: [part])

        #expect(score.displayedMeasureNumber(at: 0) == nil)
        #expect(score.displayedMeasureNumber(at: 1) == 1)
        #expect(score.displayedMeasureNumber(at: 2) == 2)

        let regular = Score(division: 480, parts: [Part(
            id: "1",
            instrument: Instrument(id: "x", longName: "Piano"),
            staves: [Staff(measures: [
                Measure(voices: [Voice(elements: [])]),
                Measure(voices: [Voice(elements: [])]),
            ])]
        )])
        #expect(regular.displayedMeasureNumber(at: 0) == 1)
        #expect(regular.displayedMeasureNumber(at: 1) == 2)
    }

    @Test func decodesLenAttributeAndIrregularElement() throws {
        let mscx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore version="4.60">
          <Score>
            <Division>480</Division>
            <Part id="1">
              <Staff id="1"><StaffType group="pitched"><name>stdNormal</name></StaffType></Staff>
              <Instrument id="x"><longName>X</longName></Instrument>
            </Part>
            <Staff id="1">
              <Measure len="1/4">
                <irregular>1</irregular>
                <voice></voice>
              </Measure>
              <Measure>
                <voice></voice>
              </Measure>
            </Staff>
          </Score>
        </museScore>
        """
        let score = try MSCXParser.parse(Data(mscx.utf8))
        let measures = score.parts[0].staves[0].measures
        #expect(measures[0].actualLength == Fraction(numerator: 1, denominator: 4))
        #expect(measures[0].irregular == true)
        #expect(measures[1].actualLength == nil)
        #expect(measures[1].irregular == false)
    }

    @Test func mscxRoundTripsAnacrusisFields() throws {
        let pickup = Measure(
            voices: [Voice(elements: [])],
            actualLength: Fraction(numerator: 1, denominator: 4),
            irregular: true
        )
        let normal = Measure(voices: [Voice(elements: [])])
        let staff = Staff(measures: [pickup, normal])
        let part = Part(
            id: "1",
            instrument: Instrument(id: "x", longName: "Piano"),
            staves: [staff]
        )
        let score = Score(division: 480, parts: [part])

        let data = try MSCXEncoder.encode(score)
        let decoded = try MSCXParser.parse(data)
        let roundTripped = decoded.parts[0].staves[0].measures
        #expect(roundTripped[0].actualLength == Fraction(numerator: 1, denominator: 4))
        #expect(roundTripped[0].irregular == true)
        #expect(roundTripped[1].actualLength == nil)
        #expect(roundTripped[1].irregular == false)
    }

    @available(macOS 15.0, iOS 16.0, *)
    @Test func layoutSkipsMeasureNumberOnIrregularMeasures() throws {
        // Per-system head labels are only emitted for the first
        // measure of each system. Force a line break after every
        // measure so each becomes a system head and the label test
        // covers all three.
        let irregular = Measure(
            voices: [Voice(elements: [])],
            lineBreak: true,
            irregular: true
        )
        let m1 = Measure(voices: [Voice(elements: [])], lineBreak: true)
        let m2 = Measure(voices: [Voice(elements: [])])
        let staff = Staff(measures: [irregular, m1, m2])
        let part = Part(
            id: "1",
            instrument: Instrument(id: "x", longName: "Piano"),
            staves: [staff]
        )
        let score = Score(division: 480, parts: [part])

        let contexts = LayoutEngine.measureContexts(for: score)
        #expect(contexts[0].displayedMeasureNumber == nil)
        #expect(contexts[1].displayedMeasureNumber == 1)
        #expect(contexts[2].displayedMeasureNumber == 2)

        let document = LayoutEngine.layout(
            score: score, options: .init(), availableWidth: 800
        )
        let measures = document.systems.flatMap(\.measures)
        func numberLabel(at index: Int) -> String? {
            guard let m = measures.first(where: { $0.measureIndex == index })
            else { return nil }
            for marker in m.markers {
                if case let .measureNumber(text, _) = marker { return text }
            }
            return nil
        }
        #expect(numberLabel(at: 0) == nil)
        #expect(numberLabel(at: 1) == "1")
        #expect(numberLabel(at: 2) == "2")
    }
}
