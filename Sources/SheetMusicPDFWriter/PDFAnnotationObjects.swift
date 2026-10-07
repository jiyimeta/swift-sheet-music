// Sources/SheetMusicPDFWriter/PDFAnnotationObjects.swift
import SheetMusicFoundation

/// Where numbered objects are written: a new file (`PDFObjectWriter`) or an update appended to one
/// (`PDFIncrementalWriter`).
protocol PDFObjectSink: AnyObject {
    func reserve() -> Int
    func object(_ number: Int, _ body: String)
    func stream(_ number: Int, dictionary: String, data: Data, compress: Bool) throws
}

/// Page annotations as objects: each an annotation dictionary and its normal appearance, a form XObject drawn in the
/// page's default user space — its `/BBox` is the annotation's `/Rect`, so no viewer rescales it.
enum PDFAnnotationObjects {
    /// Writes `annotations` for a page whose displayed space is `space`, returning the annotation objects' numbers in
    /// order, for the page's `/Annots`. An annotation that would draw nothing is left out.
    static func write(
        _ annotations: [PDFPageAnnotation], in space: PDFPageSpace, into sink: some PDFObjectSink,
    ) throws -> [Int] {
        var numbers: [Int] = []
        for annotation in annotations {
            let number = switch annotation {
            case let .ink(ink): try write(ink, in: space, into: sink)
            case let .highlight(highlight): try write(highlight, in: space, into: sink)
            }
            if let number { numbers.append(number) }
        }
        return numbers
    }

    private static func write(
        _ ink: PDFInkAnnotation, in space: PDFPageSpace, into sink: some PDFObjectSink,
    ) throws -> Int? {
        if let clip = ink.clip, !clip.elements.contains(where: { if case .close = $0 { false } else { true } }) {
            return nil
        }
        let figures = ink.appearance.filter { $0.count >= 3 }.map { $0.map(space.user) }
        let lines = ink.inkList.filter { !$0.isEmpty }.map { $0.map(space.user) }
        guard var box = Box(figures.joined()) else { return nil }
        if let centers = Box(lines.joined()) {
            box.formUnion(centers)
        }
        box = box.padded(by: max(0, ink.width) / 2)
        let opacity = n(min(1, max(0, ink.opacity)))
        var content = "q /GS0 gs \(rgb(ink.color)) rg\n"
        if let clip = ink.clip {
            content += path(clip.elements, in: space) + (clip.evenOdd ? "W* n\n" : "W n\n")
        }
        for figure in figures {
            content += polygon(figure)
        }
        content += "f\nQ\n"
        let form = try appearance(
            content, box: box, graphicsState: "<< /ca \(opacity) /CA \(opacity) >>", into: sink,
        )
        let inkList = lines.map { "[" + $0.map { "\(n($0.x)) \(n($0.y))" }.joined(separator: " ") + "]" }
        let annotation = sink.reserve()
        sink.object(
            annotation,
            "<< /Type /Annot /Subtype /Ink /Rect \(box.array) /InkList [\(inkList.joined(separator: " "))] "
                + "/BS << /W \(n(max(0, ink.width))) >> /C [\(rgb(ink.color))] /CA \(opacity) /F 4 "
                + "/AP << /N \(form) 0 R >> >>",
        )
        return annotation
    }

    private static func write(
        _ highlight: PDFHighlightAnnotation, in space: PDFPageSpace, into sink: some PDFObjectSink,
    ) throws -> Int? {
        let rect = highlight.rect
        guard rect.width > 0, rect.height > 0 else { return nil }
        // Top-left, top-right, bottom-left, bottom-right: the order Acrobat and PDFKit read `/QuadPoints` in.
        let corners = [
            PDFPagePoint(x: rect.x, y: rect.y), PDFPagePoint(x: rect.x + rect.width, y: rect.y),
            PDFPagePoint(x: rect.x, y: rect.y + rect.height),
            PDFPagePoint(x: rect.x + rect.width, y: rect.y + rect.height),
        ].map(space.user)
        guard let box = Box(corners) else { return nil }
        let outline = [corners[0], corners[1], corners[3], corners[2]]
        let form = try appearance(
            "q /GS0 gs \(rgb(highlight.color)) rg\n" + polygon(outline) + "f\nQ\n", box: box,
            graphicsState: "<< /BM /Multiply >>", into: sink,
        )
        let quads = corners.map { "\(n($0.x)) \(n($0.y))" }.joined(separator: " ")
        let annotation = sink.reserve()
        sink.object(
            annotation,
            "<< /Type /Annot /Subtype /Highlight /Rect \(box.array) /QuadPoints [\(quads)] "
                + "/C [\(rgb(highlight.color))] /F 4 /AP << /N \(form) 0 R >> >>",
        )
        return annotation
    }

    private static func appearance(
        _ content: String, box: Box, graphicsState: String, into sink: some PDFObjectSink,
    ) throws -> Int {
        let form = sink.reserve()
        try sink.stream(
            form,
            dictionary: "/Type /XObject /Subtype /Form /BBox \(box.array) "
                + "/Resources << /ExtGState << /GS0 \(graphicsState) >> >>",
            data: Data(content.utf8), compress: true,
        )
        return form
    }

    private static func polygon(_ points: [(x: Double, y: Double)]) -> String {
        guard let first = points.first else { return "" }
        var path = "\(n(first.x)) \(n(first.y)) m\n"
        for point in points.dropFirst() {
            path += "\(n(point.x)) \(n(point.y)) l\n"
        }
        return path + "h\n"
    }

    /// `elements` in user space. A quad becomes the cubic that draws it exactly: each control point two thirds of the
    /// way from an end to the quad's control. A curve with no current point starts one at its end.
    private static func path(_ elements: [PDFPathElement], in space: PDFPageSpace) -> String {
        var path = ""
        var current: PDFPagePoint?
        var subpathStart: PDFPagePoint?
        func point(_ p: PDFPagePoint) -> String {
            let user = space.user(p)
            return "\(n(user.x)) \(n(user.y))"
        }
        for element in elements {
            switch element {
            case let .move(p):
                path += "\(point(p)) m\n"
                current = p
                subpathStart = p
            case let .line(p):
                if current == nil { subpathStart = p }
                path += "\(point(p)) \(current == nil ? "m" : "l")\n"
                current = p
            case let .quad(control, end):
                guard let start = current else {
                    path += "\(point(end)) m\n"
                    current = end
                    subpathStart = end
                    continue
                }
                let first = PDFPagePoint(
                    x: start.x + 2 / 3 * (control.x - start.x),
                    y: start.y + 2 / 3 * (control.y - start.y),
                )
                let second = PDFPagePoint(
                    x: end.x + 2 / 3 * (control.x - end.x),
                    y: end.y + 2 / 3 * (control.y - end.y),
                )
                path += "\(point(first)) \(point(second)) \(point(end)) c\n"
                current = end
            case let .cubic(first, second, end):
                guard current != nil else {
                    path += "\(point(end)) m\n"
                    current = end
                    subpathStart = end
                    continue
                }
                path += "\(point(first)) \(point(second)) \(point(end)) c\n"
                current = end
            case .close:
                if let subpathStart {
                    path += "h\n"
                    current = subpathStart
                }
            }
        }
        return path
    }

    private static func rgb(_ color: PDFRGB) -> String {
        [color.red, color.green, color.blue].map { n(min(1, max(0, $0))) }.joined(separator: " ")
    }

    private static func n(_ value: Double) -> String {
        PDFPageWalker.number(value)
    }

    /// A user-space bounding box.
    struct Box {
        var minX: Double, minY: Double, maxX: Double, maxY: Double

        init?(_ points: some Sequence<(x: Double, y: Double)>) {
            var iterator = points.makeIterator()
            guard let first = iterator.next() else { return nil }
            (minX, maxX, minY, maxY) = (first.x, first.x, first.y, first.y)
            while let point = iterator.next() {
                minX = min(minX, point.x)
                maxX = max(maxX, point.x)
                minY = min(minY, point.y)
                maxY = max(maxY, point.y)
            }
        }

        mutating func formUnion(_ other: Box) {
            minX = min(minX, other.minX)
            minY = min(minY, other.minY)
            maxX = max(maxX, other.maxX)
            maxY = max(maxY, other.maxY)
        }

        func padded(by amount: Double) -> Box {
            var box = self
            box.minX -= amount
            box.minY -= amount
            box.maxX += amount
            box.maxY += amount
            return box
        }

        var array: String {
            "[\(PDFPageWalker.number(minX)) \(PDFPageWalker.number(minY)) "
                + "\(PDFPageWalker.number(maxX)) \(PDFPageWalker.number(maxY))]"
        }
    }
}
