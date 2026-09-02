#if !os(Android) && !os(WASI)
    import Foundation

    /// Page-label file format, schema v1 (spec §7.1). All coordinates are
    /// PDF page-space points, y-up. Bboxes are `[x0, y0, x1, y1]` with
    /// x0 ≤ x1, y0 ≤ y1; points are `[x, y]`.
    struct OMRPageLabels: Codable, Equatable {
        var schema: Int
        var page: Page
        var image: Image
        var glyphs: [Glyph]
        var paths: [Path]
        var beams: [Beam]
        var curves: [Curve]
        var texts: [Text]
        var census: Census

        struct Page: Codable, Equatable {
            var index: Int
            var widthPt: Double
            var heightPt: Double
            enum CodingKeys: String, CodingKey {
                case index
                case widthPt = "width_pt"
                case heightPt = "height_pt"
            }
        }

        struct Image: Codable, Equatable {
            var file: String
            var dpi: Int
            /// Row-major 3×3 homography, clean-raster pixel space →
            /// degraded-image pixel space. Identity for clean rasters;
            /// the frozen eval set (degrade.py) writes the composition.
            var labelTransform: [Double]
            /// `[width, height]` of the CLEAN raster, in pixels. Written
            /// only by the frozen eval set, where the degraded image has
            /// been resampled and is a different size — the y-flip that
            /// takes a label from page points to clean pixels has to be
            /// anchored to the clean raster, not to the degraded one.
            /// Absent (nil) on clean labels, where the two coincide.
            var sourceSizePx: [Int]?
            enum CodingKeys: String, CodingKey {
                case file, dpi
                case labelTransform = "label_transform"
                case sourceSizePx = "source_size_px"
            }
        }

        struct Glyph: Codable, Equatable {
            var className: String
            /// Ink bounding box; nil when no outline was resolvable
            /// (reserved classes, damaged subsets). Detectors need it;
            /// the oracle does not consume it.
            var bboxPt: [Double]?
            var originPt: [Double]
            var advancePt: Double
            var renderedSizePt: Double
            /// Vector-only text-space font size, preserved for oracle
            /// losslessness (staff5Lines path). Raster front-ends write 0.
            var fontSizePt: Double
            enum CodingKeys: String, CodingKey {
                case className = "class"
                case bboxPt = "bbox_pt"
                case originPt = "origin_pt"
                case advancePt = "advance_pt"
                case renderedSizePt = "rendered_size_pt"
                case fontSizePt = "font_size_pt"
            }

            /// Hand-written ONLY to write `bbox_pt` as an explicit `null`
            /// when no outline was resolvable. The synthesized encoding uses
            /// `encodeIfPresent`, which OMITS the key — and the consumer
            /// named in the plan is Python, where `label["bbox_pt"]` then
            /// raises `KeyError` instead of yielding `None`. An unrecoverable
            /// bbox is a fact this format states, not one the reader infers
            /// from an absence.
            ///
            /// Decoding is left synthesized (`decodeIfPresent`), so an
            /// explicit `null` AND an absent key both still decode to nil —
            /// label files written before this change keep reading.
            ///
            /// Every other key keeps its synthesized behavior; `.sortedKeys`
            /// fixes the on-the-wire order regardless of the sequence here,
            /// so canonical bytes are unaffected (gate P3c-G1).
            func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(className, forKey: .className)
                try container.encode(bboxPt, forKey: .bboxPt)
                try container.encode(originPt, forKey: .originPt)
                try container.encode(advancePt, forKey: .advancePt)
                try container.encode(renderedSizePt, forKey: .renderedSizePt)
                try container.encode(fontSizePt, forKey: .fontSizePt)
            }
        }

        struct Path: Codable, Equatable {
            /// "horizontal" | "vertical" | "rectangle" | "beam"
            /// ("beam" only for the degenerate quad-less case).
            var kind: String
            var rectPt: [Double]
            var lineWidthPt: Double
            enum CodingKeys: String, CodingKey {
                case kind
                case rectPt = "rect_pt"
                case lineWidthPt = "line_width_pt"
            }
        }

        struct Beam: Codable, Equatable {
            var rectPt: [Double]
            var lineWidthPt: Double
            var x0: Double
            var x1: Double
            var topSlope: Double
            var topIntercept: Double
            var botSlope: Double
            var botIntercept: Double
            enum CodingKeys: String, CodingKey {
                case rectPt = "rect_pt"
                case lineWidthPt = "line_width_pt"
                case x0, x1
                case topSlope = "top_slope"
                case topIntercept = "top_intercept"
                case botSlope = "bot_slope"
                case botIntercept = "bot_intercept"
            }
        }

        struct Curve: Codable, Equatable {
            var bboxPt: [Double]
            var leftPt: [Double]
            var rightPt: [Double]
            enum CodingKeys: String, CodingKey {
                case bboxPt = "bbox_pt"
                case leftPt = "left_pt"
                case rightPt = "right_pt"
            }
        }

        struct Text: Codable, Equatable {
            var text: String
            /// Raw font resource data preserved for oracle losslessness:
            /// lyric row/run grouping is calibrated against the raw Tf
            /// operand (see TextGlyph.fontSize doc in Internal.swift).
            var fontName: String
            var fontSizeTf: Double
            var renderedSizePt: Double
            var originPt: [Double]
            enum CodingKeys: String, CodingKey {
                case text
                case fontName = "font_name"
                case fontSizeTf = "font_size_tf"
                case renderedSizePt = "rendered_size_pt"
                case originPt = "origin_pt"
            }
        }

        struct Census: Codable, Equatable {
            var glyphsByClass: [String: Int]
            var texts: Int
            enum CodingKeys: String, CodingKey {
                case glyphsByClass = "glyphs_by_class"
                case texts
            }
        }
    }
#endif
