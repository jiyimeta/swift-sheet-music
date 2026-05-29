import Foundation

/// Page-level chrome — headers, footers, and the standalone
/// page-number renderer that pre-4.4 MuseScore conflated with the
/// header. Source: `engraving/style/styledef.cpp:487-635, 1586-1646`.
public struct PageChrome: Sendable, Equatable {
    public var header: HeaderFooter
    public var footer: HeaderFooter
    public var pageNumber: PageNumberStyle

    public init(
        header: HeaderFooter,
        footer: HeaderFooter,
        pageNumber: PageNumberStyle,
    ) {
        self.header = header
        self.footer = footer
        self.pageNumber = pageNumber
    }

    public static let museScoreDefaults = PageChrome(
        header: .museScoreDefaultHeader,
        footer: .museScoreDefaultFooter,
        pageNumber: .museScoreDefaultPageNumber,
    )
}

/// One header or footer block, with separate odd / even rows and the
/// flags that decide when each is shown.
public struct HeaderFooter: Sendable, Equatable {
    /// `showHeader` / `showFooter` (default true).
    public var enabled: Bool
    /// `headerFirstPage` (default false) /
    /// `footerFirstPage` (default true).
    public var showOnFirstPage: Bool
    /// `headerOddEven` / `footerOddEven`. When `false`, only the
    /// `odd` row is used on every page.
    public var oddEvenDifferent: Bool
    /// Even-page row. Ignored when `oddEvenDifferent == false`.
    public var even: TextRow
    /// Odd-page row. Also used on every page when
    /// `oddEvenDifferent == false`.
    public var odd: TextRow
    public var fontFace: String
    /// Points. C++: `Sid::headerFontSize` / `Sid::footerFontSize`.
    /// Default 9 (both header and footer).
    public var fontSize: Double
    public var fontStyle: FontStyleSet

    public init(
        enabled: Bool,
        showOnFirstPage: Bool,
        oddEvenDifferent: Bool,
        even: TextRow,
        odd: TextRow,
        fontFace: String,
        fontSize: Double,
        fontStyle: FontStyleSet,
    ) {
        self.enabled = enabled
        self.showOnFirstPage = showOnFirstPage
        self.oddEvenDifferent = oddEvenDifferent
        self.even = even
        self.odd = odd
        self.fontFace = fontFace
        self.fontSize = fontSize
        self.fontStyle = fontStyle
    }

    /// Default header per `styledef.cpp:616-624`:
    /// page number on the right of odd pages, left of even pages,
    /// hidden on page 1.
    public static let museScoreDefaultHeader = HeaderFooter(
        enabled: true,
        showOnFirstPage: false,
        oddEvenDifferent: true,
        even: TextRow(left: "$p", center: "", right: ""),
        odd: TextRow(left: "", center: "", right: "$p"),
        fontFace: "Edwin",
        fontSize: 9,
        fontStyle: [],
    )

    /// Default footer per `styledef.cpp:625-634`:
    /// copyright in the center on every page.
    public static let museScoreDefaultFooter = HeaderFooter(
        enabled: true,
        showOnFirstPage: true,
        oddEvenDifferent: true,
        even: TextRow(left: "", center: "$C", right: ""),
        odd: TextRow(left: "", center: "$C", right: ""),
        fontFace: "Edwin",
        fontSize: 9,
        fontStyle: [],
    )
}

/// Three-column text strip — one header or footer row.
public struct TextRow: Sendable, Equatable {
    public var left: String
    public var center: String
    public var right: String

    public init(left: String, center: String, right: String) {
        self.left = left
        self.center = center
        self.right = right
    }
}

/// Standalone page-number font / on-off style. The text content
/// itself comes from the header/footer macros (`$P`, `$p`, `$N`);
/// these fields override the surrounding font when a row's expanded
/// content is purely a page-number macro. C++:
/// `Sid::pageNumberFont*` (`styledef.cpp:1636-1646`).
public struct PageNumberStyle: Sendable, Equatable {
    public var enabled: Bool
    public var showOnFirstPage: Bool
    public var oddEvenDifferent: Bool
    public var fontFace: String
    /// Points. Default 11.
    public var fontSize: Double

    public init(
        enabled: Bool,
        showOnFirstPage: Bool,
        oddEvenDifferent: Bool,
        fontFace: String,
        fontSize: Double,
    ) {
        self.enabled = enabled
        self.showOnFirstPage = showOnFirstPage
        self.oddEvenDifferent = oddEvenDifferent
        self.fontFace = fontFace
        self.fontSize = fontSize
    }

    public static let museScoreDefaultPageNumber = PageNumberStyle(
        enabled: true,
        showOnFirstPage: false,
        oddEvenDifferent: true,
        fontFace: "Edwin",
        fontSize: 11,
    )
}

/// Bitmask of font weights / decorations. Mirrors MuseScore's
/// `FontStyle` enum (`engraving/dom/mscore.h`), which is bit-packed
/// rather than mutually exclusive.
public struct FontStyleSet: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let bold = FontStyleSet(rawValue: 1 << 0)
    public static let italic = FontStyleSet(rawValue: 1 << 1)
    public static let underline = FontStyleSet(rawValue: 1 << 2)
    public static let strike = FontStyleSet(rawValue: 1 << 3)
}
