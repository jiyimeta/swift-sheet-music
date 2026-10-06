import SheetMusicFoundation
import Wirelet

/// One element of the output of `nativeStaffBands`: one staff's band in one system (`LayoutDocument.staffBands`), its
/// staff in FULL-score addressing and its rectangle in document millimetres. A host keeps the bands of the staves it
/// highlights and fills them in its own color.
@WireFormat
public struct StaffBandWire: Equatable {
    public let partIndex: Int32
    public let staffIndexInPart: Int32
    public let xMm: Double
    public let yMm: Double
    public let widthMm: Double
    public let heightMm: Double

    public init(
        partIndex: Int32, staffIndexInPart: Int32, xMm: Double, yMm: Double, widthMm: Double, heightMm: Double,
    ) {
        self.partIndex = partIndex
        self.staffIndexInPart = staffIndexInPart
        self.xMm = xMm
        self.yMm = yMm
        self.widthMm = widthMm
        self.heightMm = heightMm
    }
}
