#if !os(Android)
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicPDF
    import Testing

    struct OMRLabelClassNamesTests {
        @Test func detectorVocabularyHas64UniqueClasses() {
            let v = OMRLabelClassNames.detectorVocabulary
            #expect(v.count == 64)
            #expect(Set(v).count == 64)
            // Reserved names must not leak into the detector vocabulary.
            for reserved in ["stem", "staff5Lines", "rest128th", "rest256th", "restOther"] {
                #expect(!v.contains(reserved))
            }
        }

        @Test func roundTripsEveryDetectorClass() {
            for name in OMRLabelClassNames.detectorVocabulary {
                let semantic = OMRLabelClassNames.semantic(forClassName: name)
                #expect(semantic != nil, "no semantic for \(name)")
                if let semantic {
                    #expect(OMRLabelClassNames.className(for: semantic) == name)
                }
            }
        }

        @Test func spotChecksMatchSpecExamples() {
            #expect(OMRLabelClassNames.className(for: .rest(.eighth)) == "rest8th")
            #expect(OMRLabelClassNames.className(for: .timeSignatureDigit(4)) == "timeSig4")
            #expect(OMRLabelClassNames.className(for: .noteheadBlack) == "noteheadBlack")
            #expect(OMRLabelClassNames.className(for: .clefG8vb) == "clefG8vb")
            #expect(OMRLabelClassNames.semantic(forClassName: "timeSig9") == .timeSignatureDigit(9))
        }

        @Test func reservedClassesAreRepresentable() {
            #expect(OMRLabelClassNames.className(for: .stem) == "stem")
            #expect(OMRLabelClassNames.className(for: .staff5Lines) == "staff5Lines")
            #expect(OMRLabelClassNames.semantic(forClassName: "stem") == .stem)
            #expect(OMRLabelClassNames.semantic(forClassName: "staff5Lines") == .staff5Lines)
        }

        @Test func unknownCodepointRoundTripsThroughHexName() {
            #expect(OMRLabelClassNames.className(for: .unknown(0xE0F3)) == "unknownE0F3")
            #expect(OMRLabelClassNames.semantic(forClassName: "unknownE0F3") == .unknown(0xE0F3))
            #expect(OMRLabelClassNames.semantic(forClassName: "unknownZZ") == nil)
        }

        @Test func unmappableNamesReturnNil() {
            #expect(OMRLabelClassNames.semantic(forClassName: "") == nil)
            #expect(OMRLabelClassNames.semantic(forClassName: "notAClass") == nil)
        }

        @Test func restOtherIsDeliberatelyNotInvertible() {
            // .fraction / .measure both collapse to "restOther"; the
            // duration parameters are gone, so there is no unique
            // semantic to return. This must stay nil — never a
            // fabricated duration (see the type doc comment).
            #expect(OMRLabelClassNames.className(for: .rest(.fraction(
                Fraction(numerator: 1, denominator: 12),
            ))) == "restOther")
            #expect(OMRLabelClassNames.className(for: .rest(.measure)) == "restOther")
            #expect(OMRLabelClassNames.semantic(forClassName: "restOther") == nil)
        }
    }
#endif
