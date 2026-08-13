#if !os(Android)
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
#endif
