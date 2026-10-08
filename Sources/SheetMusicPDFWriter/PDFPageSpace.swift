// Sources/SheetMusicPDFWriter/PDFPageSpace.swift
// A page's displayed space mapped into its default user space, where annotation geometry is written. Displayed means
// what a viewer shows: the crop box, y down from its top-left, after `/Rotate` has turned the page clockwise.
import SheetMusicPDFSyntax

struct PDFPageSpace: Equatable {
    let left: Double
    let bottom: Double
    let right: Double
    let top: Double
    /// 0, 90, 180 or 270, clockwise. Anything that is not a quarter turn reads as 0, as viewers treat it.
    let rotation: Int
    /// Physical points per default user-space unit; `/UserUnit` is local to the page, not inherited.
    let userUnit: Double

    init(left: Double, bottom: Double, right: Double, top: Double, rotation: Int, userUnit: Double = 1) {
        self.left = min(left, right)
        self.bottom = min(bottom, top)
        self.right = max(left, right)
        self.top = max(bottom, top)
        let turned = (rotation % 360 + 360) % 360
        self.rotation = turned % 90 == 0 ? turned : 0
        self.userUnit = userUnit
    }

    /// A page this writer made: its media box at the origin, unturned.
    init(width: Double, height: Double) {
        self.init(left: 0, bottom: 0, right: width, top: height, rotation: 0)
    }

    var displayedSize: PDFPageSize {
        let width = (right - left) * userUnit
        let height = (top - bottom) * userUnit
        return rotation == 90 || rotation == 270
            ? PDFPageSize(width: height, height: width) : PDFPageSize(width: width, height: height)
    }

    /// `point` in default user space. Turning a page clockwise by 90° moves its bottom-left corner to the displayed
    /// top-left, which is where each case starts counting from.
    func user(_ point: PDFPagePoint) -> (x: Double, y: Double) {
        let x = userLength(point.x), y = userLength(point.y)
        return switch rotation {
        case 90: (left + y, bottom + x)
        case 180: (right - x, bottom + y)
        case 270: (right - y, top - x)
        default: (left + x, top - y)
        }
    }

    func userLength(_ points: Double) -> Double {
        points / userUnit
    }

    /// Keep legacy Unit1 bytes; other scales need full precision so small physical marks do not round to zero.
    func number(_ value: Double) -> String {
        guard userUnit != 1 else { return PDFPageWalker.number(value) }
        let decimal = PDFBytes.decimal(value)
        return decimal.hasSuffix(".0") ? String(decimal.dropLast(2)) : decimal
    }
}
