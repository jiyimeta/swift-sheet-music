/// Sources/SheetMusicPDFWriter/PDFPageSpace.swift
/// A page's displayed space mapped into its default user space, where annotation geometry is written. Displayed means
/// what a viewer shows: the crop box, y down from its top-left, after `/Rotate` has turned the page clockwise.
struct PDFPageSpace: Equatable {
    let left: Double
    let bottom: Double
    let right: Double
    let top: Double
    /// 0, 90, 180 or 270, clockwise. Anything that is not a quarter turn reads as 0, as viewers treat it.
    let rotation: Int

    init(left: Double, bottom: Double, right: Double, top: Double, rotation: Int) {
        self.left = min(left, right)
        self.bottom = min(bottom, top)
        self.right = max(left, right)
        self.top = max(bottom, top)
        let turned = (rotation % 360 + 360) % 360
        self.rotation = turned % 90 == 0 ? turned : 0
    }

    /// A page this writer made: its media box at the origin, unturned.
    init(width: Double, height: Double) {
        self.init(left: 0, bottom: 0, right: width, top: height, rotation: 0)
    }

    var displayedSize: PDFPageSize {
        let width = right - left
        let height = top - bottom
        return rotation == 90 || rotation == 270
            ? PDFPageSize(width: height, height: width) : PDFPageSize(width: width, height: height)
    }

    /// `point` in default user space. Turning a page clockwise by 90° moves its bottom-left corner to the displayed
    /// top-left, which is where each case starts counting from.
    func user(_ point: PDFPagePoint) -> (x: Double, y: Double) {
        switch rotation {
        case 90: (left + point.y, bottom + point.x)
        case 180: (right - point.x, bottom + point.y)
        case 270: (right - point.y, top - point.x)
        default: (left + point.x, top - point.y)
        }
    }
}
