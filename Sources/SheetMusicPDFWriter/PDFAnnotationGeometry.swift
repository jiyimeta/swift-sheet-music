/// Validates every coordinate before the shared annotation writer can allocate objects or serialize fixed-point
/// numbers. Finite inputs can still overflow while being transformed, padded, or converted from quadratic curves.
enum PDFAnnotationGeometry {
    static func isRepresentable(_ annotation: PDFPageAnnotation, in space: PDFPageSpace) -> Bool {
        switch annotation {
        case let .ink(ink):
            guard valid(ink.color), ink.opacity.isFinite, valid(ink.width) else { return false }
            let figures = ink.appearance.filter { $0.count >= 3 }.flatMap { $0.map(space.user) }
            let lines = ink.inkList.flatMap { $0.map(space.user) }
            guard figures.allSatisfy(valid), lines.allSatisfy(valid),
                  var box = PDFAnnotationObjects.Box(figures)
            else { return false }
            if let centers = PDFAnnotationObjects.Box(lines) { box.formUnion(centers) }
            guard valid(box.padded(by: max(0, ink.width) / 2)) else { return false }
            return ink.clip.map { valid($0.elements, in: space) } ?? true
        case let .highlight(highlight):
            let rect = highlight.rect
            guard valid(highlight.color), [rect.x, rect.y, rect.width, rect.height].allSatisfy(valid) else {
                return false
            }
            return [
                PDFPagePoint(x: rect.x, y: rect.y), PDFPagePoint(x: rect.x + rect.width, y: rect.y),
                PDFPagePoint(x: rect.x, y: rect.y + rect.height),
                PDFPagePoint(x: rect.x + rect.width, y: rect.y + rect.height),
            ].map(space.user).allSatisfy(valid)
        }
    }

    private static func valid(_ value: Double) -> Bool {
        let scaled = (value * 1000).rounded()
        // Strict bounds also keep abs(Int.min) and Double's rounded representation of Int.max unreachable.
        return scaled.isFinite && scaled > Double(Int.min) && scaled < Double(Int.max)
    }

    private static func valid(_ point: (x: Double, y: Double)) -> Bool {
        valid(point.x) && valid(point.y)
    }

    private static func valid(_ color: PDFRGB) -> Bool {
        [color.red, color.green, color.blue].allSatisfy(\.isFinite)
    }

    private static func valid(_ box: PDFAnnotationObjects.Box) -> Bool {
        [box.minX, box.minY, box.maxX, box.maxY].allSatisfy(valid)
    }

    private static func valid(_ elements: [PDFPathElement], in space: PDFPageSpace) -> Bool {
        var current: PDFPagePoint?
        var subpathStart: PDFPagePoint?
        func point(_ point: PDFPagePoint) -> Bool {
            valid(point.x) && valid(point.y) && valid(space.user(point))
        }
        for element in elements {
            switch element {
            case let .move(end):
                guard point(end) else { return false }
                current = end
                subpathStart = end
            case let .line(end):
                guard point(end) else { return false }
                if current == nil { subpathStart = end }
                current = end
            case let .quad(control, end):
                guard point(control), point(end) else { return false }
                if let start = current {
                    let first = PDFPagePoint(
                        x: start.x + 2 / 3 * (control.x - start.x), y: start.y + 2 / 3 * (control.y - start.y),
                    )
                    let second = PDFPagePoint(
                        x: end.x + 2 / 3 * (control.x - end.x), y: end.y + 2 / 3 * (control.y - end.y),
                    )
                    guard point(first), point(second) else { return false }
                } else { subpathStart = end }
                current = end
            case let .cubic(first, second, end):
                guard point(first), point(second), point(end) else { return false }
                if current == nil { subpathStart = end }
                current = end
            case .close:
                if let subpathStart { current = subpathStart }
            }
        }
        return true
    }
}
