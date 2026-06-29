/// Notehead glyph tables. Mirrors `noteHeads[2][HEAD_GROUPS][HEAD_TYPES]`
/// from src/engraving/dom/note.cpp:89-322.
extension NoteHeadGroup {
    /// Down-stem (noteHeads[0]) glyph name table.
    /// Each row is [whole, half, quarter, doubleWhole].
    static let downStemTable: [NoteHeadGroup: [String]] = [
        .normal: ["noteheadWhole", "noteheadHalf", "noteheadBlack", "noteheadDoubleWhole"],
        .cross: ["noteheadXWhole", "noteheadXHalf", "noteheadXBlack", "noteheadXDoubleWhole"],
        .plus: ["noteheadPlusWhole", "noteheadPlusHalf", "noteheadPlusBlack", "noteheadPlusDoubleWhole"],
        .xcircle: ["noteheadCircleXWhole", "noteheadCircleXHalf", "noteheadCircleX", "noteheadCircleXDoubleWhole"],
        .withX: ["noteheadWholeWithX", "noteheadHalfWithX", "noteheadVoidWithX", "noteheadDoubleWholeWithX"],
        // swiftlint:disable:next line_length
        .triangleUp: ["noteheadTriangleUpWhole", "noteheadTriangleUpHalf", "noteheadTriangleUpBlack", "noteheadTriangleUpDoubleWhole"],
        // swiftlint:disable:next line_length
        .triangleDown: ["noteheadTriangleDownWhole", "noteheadTriangleDownHalf", "noteheadTriangleDownBlack", "noteheadTriangleDownDoubleWhole"],
        // swiftlint:disable:next line_length
        .slashed1: ["noteheadSlashedWhole1", "noteheadSlashedHalf1", "noteheadSlashedBlack1", "noteheadSlashedDoubleWhole1"],
        // swiftlint:disable:next line_length
        .slashed2: ["noteheadSlashedWhole2", "noteheadSlashedHalf2", "noteheadSlashedBlack2", "noteheadSlashedDoubleWhole2"],
        .diamond: ["noteheadDiamondWhole", "noteheadDiamondHalf", "noteheadDiamondBlack", "noteheadDiamondDoubleWhole"],
        // swiftlint:disable:next line_length
        .diamondOld: ["noteheadDiamondWholeOld", "noteheadDiamondHalfOld", "noteheadDiamondBlackOld", "noteheadDiamondDoubleWholeOld"],
        .circled: ["noteheadCircledWhole", "noteheadCircledHalf", "noteheadCircledBlack", "noteheadCircledDoubleWhole"],
        // swiftlint:disable:next line_length
        .circledLarge: ["noteheadCircledWholeLarge", "noteheadCircledHalfLarge", "noteheadCircledBlackLarge", "noteheadCircledDoubleWholeLarge"],
        // swiftlint:disable:next line_length
        .largeArrow: ["noteheadLargeArrowUpWhole", "noteheadLargeArrowUpHalf", "noteheadLargeArrowUpBlack", "noteheadLargeArrowUpDoubleWhole"],
        .brevisAlt: ["noteheadWhole", "noteheadHalf", "noteheadBlack", "noteheadDoubleWholeSquare"],
        // swiftlint:disable:next line_length
        .slash: ["noteheadSlashWhiteWhole", "noteheadSlashWhiteHalf", "noteheadSlashHorizontalEnds", "noteheadSlashWhiteWhole"],
        // swiftlint:disable:next line_length
        .largeDiamond: ["noteheadSlashDiamondWhite", "noteheadSlashDiamondWhite", "noteheadSlashHorizontalEnds", "noteheadSlashWhiteWhole"],
        .heavyCross: ["noteheadHeavyX", "noteheadHeavyX", "noteheadHeavyX", "noteheadHeavyX"],
        .heavyCrossHat: ["noteheadHeavyXHat", "noteheadHeavyXHat", "noteheadHeavyXHat", "noteheadHeavyXHat"],
        // Shape notes
        .sol: ["noteShapeRoundWhite", "noteShapeRoundWhite", "noteShapeRoundBlack", "noteShapeRoundDoubleWhole"],
        .la: ["noteShapeSquareWhite", "noteShapeSquareWhite", "noteShapeSquareBlack", "noteShapeSquareDoubleWhole"],
        // swiftlint:disable:next line_length
        .fa: ["noteShapeTriangleRightWhite", "noteShapeTriangleRightWhite", "noteShapeTriangleRightBlack", "noteShapeTriangleRightDoubleWhole"],
        .mi: ["noteShapeDiamondWhite", "noteShapeDiamondWhite", "noteShapeDiamondBlack", "noteShapeDiamondDoubleWhole"],
        // swiftlint:disable:next line_length
        .doShape: ["noteShapeTriangleUpWhite", "noteShapeTriangleUpWhite", "noteShapeTriangleUpBlack", "noteShapeTriangleUpDoubleWhole"],
        .reShape: ["noteShapeMoonWhite", "noteShapeMoonWhite", "noteShapeMoonBlack", "noteShapeMoonDoubleWhole"],
        // swiftlint:disable:next line_length
        .tiShape: ["noteShapeTriangleRoundWhite", "noteShapeTriangleRoundWhite", "noteShapeTriangleRoundBlack", "noteShapeTriangleRoundDoubleWhole"],
        // Walker shape notes
        // swiftlint:disable:next line_length
        .doWalker: ["noteShapeKeystoneWhite", "noteShapeKeystoneWhite", "noteShapeKeystoneBlack", "noteShapeKeystoneDoubleWhole"],
        // swiftlint:disable:next line_length
        .reWalker: ["noteShapeQuarterMoonWhite", "noteShapeQuarterMoonWhite", "noteShapeQuarterMoonBlack", "noteShapeQuarterMoonDoubleWhole"],
        // swiftlint:disable:next line_length
        .tiWalker: ["noteShapeIsoscelesTriangleWhite", "noteShapeIsoscelesTriangleWhite", "noteShapeIsoscelesTriangleBlack", "noteShapeIsoscelesTriangleDoubleWhole"],
        // Funk shape notes
        // swiftlint:disable:next line_length
        .doFunk: ["noteShapeMoonLeftWhite", "noteShapeMoonLeftWhite", "noteShapeMoonLeftBlack", "noteShapeMoonLeftDoubleWhole"],
        // swiftlint:disable:next line_length
        .reFunk: ["noteShapeArrowheadLeftWhite", "noteShapeArrowheadLeftWhite", "noteShapeArrowheadLeftBlack", "noteShapeArrowheadLeftDoubleWhole"],
        // swiftlint:disable:next line_length
        .tiFunk: ["noteShapeTriangleRoundLeftWhite", "noteShapeTriangleRoundLeftWhite", "noteShapeTriangleRoundLeftBlack", "noteShapeTriangleRoundLeftDoubleWhole"],
        // Named-solfège (doubleWhole = noSym)
        .doName: ["noteDoWhole", "noteDoHalf", "noteDoBlack", "noSym"],
        .diName: ["noteDiWhole", "noteDiHalf", "noteDiBlack", "noSym"],
        .raName: ["noteRaWhole", "noteRaHalf", "noteRaBlack", "noSym"],
        .reName: ["noteReWhole", "noteReHalf", "noteReBlack", "noSym"],
        .riName: ["noteRiWhole", "noteRiHalf", "noteRiBlack", "noSym"],
        .meName: ["noteMeWhole", "noteMeHalf", "noteMeBlack", "noSym"],
        .miName: ["noteMiWhole", "noteMiHalf", "noteMiBlack", "noSym"],
        .faName: ["noteFaWhole", "noteFaHalf", "noteFaBlack", "noSym"],
        .fiName: ["noteFiWhole", "noteFiHalf", "noteFiBlack", "noSym"],
        .seName: ["noteSeWhole", "noteSeHalf", "noteSeBlack", "noSym"],
        .solName: ["noteSoWhole", "noteSoHalf", "noteSoBlack", "noSym"],
        .leName: ["noteLeWhole", "noteLeHalf", "noteLeBlack", "noSym"],
        .laName: ["noteLaWhole", "noteLaHalf", "noteLaBlack", "noSym"],
        .liName: ["noteLiWhole", "noteLiHalf", "noteLiBlack", "noSym"],
        .teName: ["noteTeWhole", "noteTeHalf", "noteTeBlack", "noSym"],
        .tiName: ["noteTiWhole", "noteTiHalf", "noteTiBlack", "noSym"],
        .siName: ["noteSiWhole", "noteSiHalf", "noteSiBlack", "noSym"],
        // Named-pitch (doubleWhole = noSym)
        .aSharpName: ["noteASharpWhole", "noteASharpHalf", "noteASharpBlack", "noSym"],
        .aName: ["noteAWhole", "noteAHalf", "noteABlack", "noSym"],
        .aFlatName: ["noteAFlatWhole", "noteAFlatHalf", "noteAFlatBlack", "noSym"],
        .bSharpName: ["noteBSharpWhole", "noteBSharpHalf", "noteBSharpBlack", "noSym"],
        .bName: ["noteBWhole", "noteBHalf", "noteBBlack", "noSym"],
        .bFlatName: ["noteBFlatWhole", "noteBFlatHalf", "noteBFlatBlack", "noSym"],
        .cSharpName: ["noteCSharpWhole", "noteCSharpHalf", "noteCSharpBlack", "noSym"],
        .cName: ["noteCWhole", "noteCHalf", "noteCBlack", "noSym"],
        .cFlatName: ["noteCFlatWhole", "noteCFlatHalf", "noteCFlatBlack", "noSym"],
        .dSharpName: ["noteDSharpWhole", "noteDSharpHalf", "noteDSharpBlack", "noSym"],
        .dName: ["noteDWhole", "noteDHalf", "noteDBlack", "noSym"],
        .dFlatName: ["noteDFlatWhole", "noteDFlatHalf", "noteDFlatBlack", "noSym"],
        .eSharpName: ["noteESharpWhole", "noteESharpHalf", "noteESharpBlack", "noSym"],
        .eName: ["noteEWhole", "noteEHalf", "noteEBlack", "noSym"],
        .eFlatName: ["noteEFlatWhole", "noteEFlatHalf", "noteEFlatBlack", "noSym"],
        .fSharpName: ["noteFSharpWhole", "noteFSharpHalf", "noteFSharpBlack", "noSym"],
        .fName: ["noteFWhole", "noteFHalf", "noteFBlack", "noSym"],
        .fFlatName: ["noteFFlatWhole", "noteFFlatHalf", "noteFFlatBlack", "noSym"],
        .gSharpName: ["noteGSharpWhole", "noteGSharpHalf", "noteGSharpBlack", "noSym"],
        .gName: ["noteGWhole", "noteGHalf", "noteGBlack", "noSym"],
        .gFlatName: ["noteGFlatWhole", "noteGFlatHalf", "noteGFlatBlack", "noSym"],
        .hName: ["noteHWhole", "noteHHalf", "noteHBlack", "noSym"],
        .hSharpName: ["noteHSharpWhole", "noteHSharpHalf", "noteHSharpBlack", "noSym"],
        // Swiss rudiments (whole and doubleWhole = noSym)
        .swissRudimentsFlam: ["noSym", "swissRudimentsNoteheadHalfFlam", "swissRudimentsNoteheadBlackFlam", "noSym"],
        // swiftlint:disable:next line_length
        .swissRudimentsDouble: ["noSym", "swissRudimentsNoteheadHalfDouble", "swissRudimentsNoteheadBlackDouble", "noSym"],
    ]

    /// Up-stem override entries that differ from downStemTable.
    /// Groups not listed here use the down-stem row.
    private static let upStemOverrides: [NoteHeadGroup: [String]] = [
        // swiftlint:disable:next line_length
        .largeArrow: ["noteheadLargeArrowDownWhole", "noteheadLargeArrowDownHalf", "noteheadLargeArrowDownBlack", "noteheadLargeArrowDownDoubleWhole"],
        // swiftlint:disable:next line_length
        .slash: ["noteheadSlashWhiteWhole", "noteheadSlashWhiteHalf", "noteheadSlashHorizontalEnds", "noteheadSlashWhiteDoubleWhole"],
        // swiftlint:disable:next line_length
        .largeDiamond: ["noteheadSlashDiamondWhite", "noteheadSlashDiamondWhite", "noteheadSlashHorizontalEnds", "noteheadSlashWhiteDoubleWhole"],
        // swiftlint:disable:next line_length
        .fa: ["noteShapeTriangleLeftWhite", "noteShapeTriangleLeftWhite", "noteShapeTriangleLeftBlack", "noteShapeTriangleLeftDoubleWhole"],
    ]

    /// Combined up-stem table (overrides merged over down-stem).
    static let upStemTable: [NoteHeadGroup: [String]] = {
        var table = downStemTable
        for (group, row) in upStemOverrides {
            table[group] = row
        }
        return table
    }()
}
