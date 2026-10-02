/// A rectangle on one page of a `ScorePages`, in that page's millimetres: the origin at the page's top-left, Y down.
///
/// Page-local, which in `.page` mode is not the `LayoutDocument`'s own space: each page after the first is laid out
/// from a slice of the continuous document lifted so its first system sits near the top, and every page's content is
/// shifted by the leading and top `ScorePageOptions.pageMarginsMM` (so a rect in page millimetres includes them).
public struct PageRectMM: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    var maxX: Double {
        x + width
    }

    var maxY: Double {
        y + height
    }
}

/// A point on one page of a `ScorePages`, in that page's millimetres (`PageRectMM`'s space): the origin at the page's
/// top-left, Y down. `LayoutBridge.PagePlacement` maps document points to it.
public struct PagePointMM: Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}
