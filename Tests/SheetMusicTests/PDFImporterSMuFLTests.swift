#if !os(Android)
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicPDF
    import Testing

    @MainActor struct PDFImporterSMuFLTests {
        @Test func mapsBraceCodepointToBraceSemantic() {
            #expect(PDFImporter.smuflSemantic(codepoint: 0xE000) == .brace)
        }

        @Test func semanticIsHashableAndDistinguishesCases() {
            let set: Set<SMuFLSemantic> = [
                .brace, .noteheadBlack, .rest(.quarter), .rest(.eighth),
                .unknown(0xE999),
            ]
            #expect(set.count == 5)
            #expect(set.contains(.rest(.quarter)))
            #expect(!set.contains(.rest(.half)))
        }

        @Test func unknownCodepointStillFallsThrough() {
            #expect(PDFImporter.smuflSemantic(codepoint: 0xE999) == .unknown(0xE999))
        }

        @Test func classifiesNoteheads() {
            #expect(PDFImporter.smuflSemantic(codepoint: 0xE0A4) == .noteheadBlack)
            #expect(PDFImporter.smuflSemantic(codepoint: 0xE0A3) == .noteheadHalf)
            #expect(PDFImporter.smuflSemantic(codepoint: 0xE0A2) == .noteheadWhole)
        }

        @Test func classifiesClefs() {
            #expect(PDFImporter.smuflSemantic(codepoint: 0xE050) == .clefG)
            #expect(PDFImporter.smuflSemantic(codepoint: 0xE062) == .clefF)
            #expect(PDFImporter.smuflSemantic(codepoint: 0xE05C) == .clefC)
        }

        @Test func classifiesTimeSignatureDigits() {
            for digit in 0 ... 9 {
                let cp = UInt32(0xE080 + digit)
                #expect(PDFImporter.smuflSemantic(codepoint: cp) == .timeSignatureDigit(digit))
            }
            #expect(PDFImporter.smuflSemantic(codepoint: 0xE08A) == .timeSignatureCommon)
            #expect(PDFImporter.smuflSemantic(codepoint: 0xE08B) == .timeSignatureCutTime)
        }

        @Test func classifiesAccidentals() {
            #expect(PDFImporter.smuflSemantic(codepoint: 0xE262) == .accidentalSharp)
            #expect(PDFImporter.smuflSemantic(codepoint: 0xE260) == .accidentalFlat)
            #expect(PDFImporter.smuflSemantic(codepoint: 0xE261) == .accidentalNatural)
        }

        @Test func classifiesFlags() {
            #expect(PDFImporter.smuflSemantic(codepoint: 0xE240) == .flag8thUp)
            #expect(PDFImporter.smuflSemantic(codepoint: 0xE241) == .flag8thDown)
            #expect(PDFImporter.smuflSemantic(codepoint: 0xE242) == .flag16thUp)
        }

        @Test func classifiesRestsByDuration() {
            #expect(PDFImporter.smuflSemantic(codepoint: 0xE4E3) == .rest(.whole))
            #expect(PDFImporter.smuflSemantic(codepoint: 0xE4E4) == .rest(.half))
            #expect(PDFImporter.smuflSemantic(codepoint: 0xE4E5) == .rest(.quarter))
            #expect(PDFImporter.smuflSemantic(codepoint: 0xE4E6) == .rest(.eighth))
            #expect(PDFImporter.smuflSemantic(codepoint: 0xE4E7) == .rest(.sixteenth))
        }

        @Test func unknownCodepointReportsAsUnknown() {
            let semantic = PDFImporter.smuflSemantic(codepoint: 0xE999)
            if case let .unknown(cp) = semantic {
                #expect(cp == 0xE999)
            } else {
                Issue.record("expected .unknown")
            }
        }

        @Test func nonPUACodepointReportsAsUnknown() {
            let semantic = PDFImporter.smuflSemantic(codepoint: 0x41)
            if case .unknown = semantic {
                // ok
            } else {
                Issue.record("expected .unknown")
            }
        }
    }
#endif
