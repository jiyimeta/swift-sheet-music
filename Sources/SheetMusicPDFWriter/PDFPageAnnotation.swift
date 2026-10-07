// Sources/SheetMusicPDFWriter/PDFPageAnnotation.swift
import SheetMusicFoundation

/// A point on a page in points from the page's top-left corner as it is displayed, y down — the space a host draws its
/// overlays in. The writer maps it into the page's PDF space: its box, y up, turned back by its `/Rotate`.
public struct PDFPagePoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// A rectangle in `PDFPagePoint`'s space: its top-left corner, then its size.
public struct PDFPageRect: Equatable, Sendable {
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
}

/// A page's size as it is displayed — its crop box, turned by its rotation — in points.
public struct PDFPageSize: Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// An sRGB color, each component in 0…1.
public struct PDFRGB: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// One element of a path in `PDFPagePoint`'s space.
public enum PDFPathElement: Equatable, Sendable {
    case move(PDFPagePoint)
    case line(PDFPagePoint)
    /// Control point, then end point.
    case quad(PDFPagePoint, PDFPagePoint)
    /// First control point, second control point, end point.
    case cubic(PDFPagePoint, PDFPagePoint, PDFPagePoint)
    case close
}

/// The region an ink annotation's appearance shows through: what falls outside it is not drawn.
public struct PDFClipPath: Equatable, Sendable {
    public var elements: [PDFPathElement]
    /// The even-odd rule decides what is inside; otherwise the nonzero rule.
    public var evenOdd: Bool

    public init(elements: [PDFPathElement], evenOdd: Bool) {
        self.elements = elements
        self.evenOdd = evenOdd
    }
}

/// A freehand stroke as a standard `/Ink` annotation, which a viewer lets the reader select and delete.
public struct PDFInkAnnotation: Equatable, Sendable {
    /// The stroke's center lines (`/InkList`): what a viewer that rebuilds an appearance strokes.
    public var inkList: [[PDFPagePoint]]
    /// The width that viewer strokes them at (`/BS /W`), in points.
    public var width: Double
    public var color: PDFRGB
    /// 0…1 (`/CA`, and the appearance's fill alpha).
    public var opacity: Double
    /// What is drawn (`/AP`): closed figures, filled once together with the nonzero rule.
    public var appearance: [[PDFPagePoint]]
    /// Where the appearance shows, or `nil` for everywhere. An empty clip shows nothing, so no annotation is written.
    public var clip: PDFClipPath?

    public init(
        inkList: [[PDFPagePoint]], width: Double, color: PDFRGB, opacity: Double, appearance: [[PDFPagePoint]],
        clip: PDFClipPath?,
    ) {
        self.inkList = inkList
        self.width = width
        self.color = color
        self.opacity = opacity
        self.appearance = appearance
        self.clip = clip
    }
}

/// A `/Highlight` annotation over a rectangle, `color` multiplied into the page beneath it.
public struct PDFHighlightAnnotation: Equatable, Sendable {
    public var rect: PDFPageRect
    public var color: PDFRGB

    public init(rect: PDFPageRect, color: PDFRGB) {
        self.rect = rect
        self.color = color
    }
}

public enum PDFPageAnnotation: Equatable, Sendable {
    case ink(PDFInkAnnotation)
    case highlight(PDFHighlightAnnotation)
}
