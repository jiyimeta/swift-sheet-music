#if !os(Android) && !os(WASI)
    import Foundation

    /// One normalized page: the detector's input image plus its targets,
    /// all in normalized pixels, y-down from the top-left.
    ///
    /// Written by the Swift prep export and read by
    /// `Training/model/prep.py`. Everything the trainer needs about a
    /// page is here, so it never walks the dataset root as well — which
    /// is what keeps a prep root self-describing and a second writer out
    /// of the dataset root's gates.
    struct OMRPrepPage: Codable, Equatable {
        var schema: Int
        var renderId: String
        var sourceId: String
        var face: String
        var pageIndex: Int
        var image: Image
        var glyphs: [Glyph]

        struct Image: Codable, Equatable {
            var file: String
            var widthPx: Int
            var heightPx: Int
            /// Pixels per staff space — the canonical scale S.
            var staffSpacePx: Double
            /// Normalized pixels per deskewed pixel.
            var scale: Double
            var sourceWidthPx: Int
            var sourceHeightPx: Int
            var sourceDpi: Double
            var deskewDegrees: Double
            enum CodingKeys: String, CodingKey {
                case file
                case widthPx = "width_px"
                case heightPx = "height_px"
                case staffSpacePx = "staff_space_px"
                case scale
                case sourceWidthPx = "source_width_px"
                case sourceHeightPx = "source_height_px"
                case sourceDpi = "source_dpi"
                case deskewDegrees = "deskew_degrees"
            }
        }

        struct Glyph: Codable, Equatable {
            var className: String
            /// Ink-bbox center — the heatmap's peak location.
            var centerPx: [Double]
            /// The SMuFL registration point the back-end is calibrated
            /// against; regressed directly, never reconstructed from the
            /// box (design §3.2).
            var originPx: [Double]
            var advancePx: Double
            var renderedSizePx: Double
            enum CodingKeys: String, CodingKey {
                case className = "class"
                case centerPx = "center_px"
                case originPx = "origin_px"
                case advancePx = "advance_px"
                case renderedSizePx = "rendered_size_px"
            }
        }

        enum CodingKeys: String, CodingKey {
            case schema
            case renderId = "render_id"
            case sourceId = "source_id"
            case face
            case pageIndex = "page_index"
            case image
            case glyphs
        }
    }

    extension OMRPrepPage {
        /// One page with two glyphs, for the schema codec tests: gives the
        /// encoder something with both nesting levels (`image` + `glyphs`)
        /// populated.
        static func sample() -> OMRPrepPage {
            OMRPrepPage(
                schema: OMRPrepSchema.version,
                renderId: "render-0001",
                sourceId: "source-0001",
                face: "Bravura",
                pageIndex: 0,
                image: Image(
                    file: "page-0000.png",
                    widthPx: 833,
                    heightPx: 417,
                    staffSpacePx: 8,
                    scale: 1,
                    sourceWidthPx: 833,
                    sourceHeightPx: 417,
                    sourceDpi: 300,
                    deskewDegrees: 0,
                ),
                glyphs: [
                    Glyph(
                        className: "noteheadBlack",
                        centerPx: [150, 117],
                        originPx: [150, 121],
                        advancePx: 12,
                        renderedSizePx: 8,
                    ),
                    Glyph(
                        className: "gClef",
                        centerPx: [40, 120],
                        originPx: [40, 148],
                        advancePx: 20,
                        renderedSizePx: 28,
                    ),
                ],
            )
        }
    }

    enum OMRPrepSchema {
        static let version = 1

        /// Canonical bytes: keys sorted, pretty-printed so dataset diffs
        /// are real diffs. Doubles are shortest-round-trip (JSONEncoder
        /// default) — bit-exact on decode.
        static func encodeCanonical(_ page: OMRPrepPage) throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [
                .prettyPrinted, .sortedKeys, .withoutEscapingSlashes,
            ]
            return try encoder.encode(page)
        }
    }
#endif
