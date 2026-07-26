#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation

/// Element category a `ShapeRect` came from. Drives the autoplace
/// ignore rules and the `minDistance` table.
///
/// C++: the `ElementType` discriminant MuseScore's
/// `Autoplace::itemsShouldIgnoreEachOther` switches on.
public enum ShapeItemKind: Sendable, Equatable, CaseIterable {
    // Base skyline — never moved by autoplace.
    case staff
    case chord
    case graceChord
    case beam
    case rest
    case note
    // No `accidental` case: `chordRects` tags an accidental's rect with
    // the OWNING CHORD's `ShapeItem`, because MuseScore's ignore rules
    // and `minDistance` treat an accidental as part of its chord. A
    // separate case would be unreachable from `kind(of:)` yet still
    // iterated by every `allCases` walk.
    case articulation
    case fermata
    case breath
    case tie
    case tupletLabel
    case barLine
    case clef
    case keySignature
    case timeSignature
    case measureRepeat
    case multiMeasureRest
    case tremolo
    case chordLine
    case arpeggio
    case glissando
    // Autoplaced.
    case dynamics
    case lyrics
    case lyricsMelisma
    case lyricHyphen
    case tempo
    case measureNumber
    case harmony
    case staffText
    case systemText
    case rehearsalMark
    case marker
    case jump
    case hairpin
    case pedal
    case volta
    case ottava
    case textLine

    /// True for kinds MuseScore treats as `TextBase` descendants. Two
    /// items of the same TEXT kind still collide with each other;
    /// two items of the same non-text kind ignore each other.
    public var isText: Bool {
        switch self {
        case .dynamics, .lyrics, .tempo, .measureNumber, .harmony,
             .staffText, .systemText, .rehearsalMark, .marker, .jump:
            true
        default:
            false
        }
    }
}

/// Identity of the element a rect belongs to. `id` is unique within
/// one (system, staff) pass, so `a.id == b.id` means "same element".
public struct ShapeItem: Sendable, Equatable {
    public let kind: ShapeItemKind
    public let id: Int

    public init(kind: ShapeItemKind, id: Int) {
        self.kind = kind
        self.id = id
    }
}

/// One rectangle of an element's shape, tagged with its owner.
public struct ShapeRect: Sendable, Equatable {
    public let rect: CGRect
    public let item: ShapeItem

    public init(rect: CGRect, item: ShapeItem) {
        self.rect = rect
        self.item = item
    }
}

/// A set of axis-aligned rectangles approximating an element's ink.
///
/// Mirrors `mu::engraving::Shape`
/// (`src/engraving/infrastructure/shape.cpp`), reduced to the
/// operations autoplace needs. Coordinates are in the same space as
/// the elements they describe (system X, staff-local Y during the
/// pass); Y grows downward, so `rect.minY` is the top edge.
public struct LayoutShape: Sendable, Equatable {
    public var rects: [ShapeRect]

    public init(rects: [ShapeRect] = []) {
        self.rects = rects
    }

    public var isEmpty: Bool {
        rects.isEmpty
    }

    /// Union of every rect, or `nil` when the shape is empty.
    public var bbox: CGRect? {
        guard let first = rects.first?.rect else { return nil }
        var minX = first.minX, maxX = first.maxX
        var minY = first.minY, maxY = first.maxY
        for r in rects.dropFirst() {
            minX = min(minX, r.rect.minX)
            maxX = max(maxX, r.rect.maxX)
            minY = min(minY, r.rect.minY)
            maxY = max(maxY, r.rect.maxY)
        }
        return CGRect(
            x: minX, y: minY, width: maxX - minX, height: maxY - minY,
        )
    }

    public func translatedY(_ dy: CGFloat) -> LayoutShape {
        LayoutShape(rects: rects.map {
            ShapeRect(
                rect: CGRect(
                    x: $0.rect.minX, y: $0.rect.minY + dy,
                    width: $0.rect.width, height: $0.rect.height,
                ),
                item: $0.item,
            )
        })
    }

    public mutating func add(_ other: LayoutShape) {
        rects.append(contentsOf: other.rects)
    }

    /// Vertical distance from `self` (the UPPER shape) down to
    /// `below` (the LOWER shape), maximized over every pair of rects
    /// whose x-ranges overlap once widened by `minHorizontalClearance`.
    ///
    /// Positive = the shapes overlap vertically by that much.
    /// Negative = that much clearance separates them.
    /// `-infinity` = no pair overlaps horizontally, i.e. the shapes
    /// cannot interact at all.
    ///
    /// Mirrors `Shape::minVerticalDistance`
    /// (`src/engraving/infrastructure/shape.cpp`).
    public func minVerticalDistance(
        _ below: LayoutShape, minHorizontalClearance: CGFloat,
    ) -> CGFloat {
        var result = -CGFloat.infinity
        for upper in rects {
            let a = upper.rect
            for lower in below.rects {
                let b = lower.rect
                guard b.maxX >= a.minX - minHorizontalClearance,
                      b.minX <= a.maxX + minHorizontalClearance
                else { continue }
                result = max(result, a.maxY - b.minY)
            }
        }
        return result
    }
}
