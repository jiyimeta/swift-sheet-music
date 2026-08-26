@testable import SheetMusicCore
import Testing

struct InstrumentTranspositionTests {
    @Test func defaultsAreNonTransposing() {
        let piano = Instrument(id: "piano")
        #expect(piano.transposeDiatonic == 0)
        #expect(piano.transposeChromatic == 0)
        #expect(!piano.isTransposing)
        #expect(piano.writtenPitchOffset == 0)
        #expect(piano.writtenFifthsOffset == 0)
    }

    @Test func bFlatClarinetOffsets() {
        let clarinet = Instrument(id: "clarinet", transposeDiatonic: -1, transposeChromatic: -2)
        #expect(clarinet.isTransposing)
        #expect(clarinet.writtenPitchOffset == 2)
        #expect(clarinet.writtenFifthsOffset == 2)
    }

    @Test func fHornAndAltoSaxAndOctaveOffsets() {
        let horn = Instrument(id: "horn", transposeDiatonic: -4, transposeChromatic: -7)
        #expect(horn.writtenPitchOffset == 7)
        #expect(horn.writtenFifthsOffset == 1)
        let altoSax = Instrument(id: "alto-sax", transposeDiatonic: -5, transposeChromatic: -9)
        #expect(altoSax.writtenPitchOffset == 9)
        #expect(altoSax.writtenFifthsOffset == 3)
        let contrabass = Instrument(id: "contrabass", transposeDiatonic: -7, transposeChromatic: -12)
        #expect(contrabass.writtenPitchOffset == 12)
        #expect(contrabass.writtenFifthsOffset == 0)
    }
}
