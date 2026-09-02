import CoreML
import Foundation
import SheetMusicCore
import SheetMusicPDF

/// The Core ML implementation of `OMRTileClassifier`.
///
/// `@unchecked Sendable` because `MLModel` is not `Sendable`. That is sound
/// rather than convenient: `MLModel.prediction` is documented thread-safe, and
/// nothing here mutates after `init`.
public struct CoreMLTileClassifier: OMRTileClassifier, @unchecked Sendable {
    public let manifest: OMRModelManifest
    private let model: MLModel

    /// The model bundled with this target. No environment, no paths.
    ///
    /// Synchronous: the bundled artifact is already compiled, so loading it
    /// is one `MLModel(contentsOf:)` with nothing to await. Only the
    /// external-root initializer below compiles at run time and is `async`.
    /// Still worth calling off the main actor — the load takes a moment.
    public init() throws {
        guard let compiled = Bundle.module.url(forResource: "model", withExtension: "mlmodelc"),
              let manifestURL = Bundle.module.url(forResource: "model", withExtension: "json")
        else {
            throw Self.fault("the bundled model resources are missing from SheetMusicOMRModel")
        }
        try self.init(compiledModelURL: compiled, manifestURL: manifestURL)
    }

    /// An external model root holding `model.json` + `model.mlpackage`. This is
    /// the downloaded-model case, so it compiles at run time; the bundled path
    /// above does not.
    public init(modelRoot: URL) async throws {
        let compiled = try await MLModel.compileModel(
            at: modelRoot.appendingPathComponent("model.mlpackage"),
        )
        try self.init(
            compiledModelURL: compiled,
            manifestURL: modelRoot.appendingPathComponent("model.json"),
        )
    }

    private init(compiledModelURL: URL, manifestURL: URL) throws {
        let manifest = try JSONDecoder().decode(
            OMRModelManifest.self, from: Data(contentsOf: manifestURL),
        )
        try manifest.validate()
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        model = try MLModel(contentsOf: compiledModelURL, configuration: configuration)
        self.manifest = manifest
    }

    public func run(tile: [Float]) throws -> OMRHeadOutputs {
        // THE POOL LIVES HERE. It used to wrap the per-tile loop on the caller's
        // side, but that loop is now portable code compiled for Android too,
        // where autoreleasepool does not exist. Every Objective-C allocation it
        // guards is on this side anyway. A per-tile loop in this repo without
        // one consumed 24GB and took the machine down.
        try autoreleasepool {
            let side = manifest.tile
            let array = try MLMultiArray(
                shape: [1, 1, NSNumber(value: side), NSNumber(value: side)], dataType: .float32,
            )
            let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: side * side)
            tile.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                pointer.update(from: base, count: side * side)
            }
            let provider = try MLDictionaryFeatureProvider(
                dictionary: ["image": MLFeatureValue(multiArray: array)],
            )
            let output = try model.prediction(from: provider)
            guard let heatmap = output.featureValue(for: "heatmap")?.multiArrayValue,
                  let offset = output.featureValue(for: "offset")?.multiArrayValue,
                  let geom = output.featureValue(for: "geom")?.multiArrayValue
            else {
                throw Self.fault("model output is missing heatmap / offset / geom")
            }
            let flatHeatmap = try Self.flatten(heatmap)
            let flatOffset = try Self.flatten(offset)
            let flatGeom = try Self.flatten(geom)
            return OMRHeadOutputs(
                heatmap: flatHeatmap.values, offset: flatOffset.values, geom: flatGeom.values,
                height: flatHeatmap.height, width: flatHeatmap.width,
            )
        }
    }

    private struct FlatArray {
        var values: [Float]
        var channels: Int
        var height: Int
        var width: Int
    }

    /// Flattens a Core ML output into CHW-order `[Float]`, the layout
    /// `OMRDetectorDecode.decode` expects, walking `strides` rather than
    /// assuming the array is contiguous — Core ML is free to lay a
    /// multi-array out however the selected compute unit prefers.
    private static func flatten(_ array: MLMultiArray) throws -> FlatArray {
        guard array.dataType == .float32 else {
            throw fault("expected a float32 model output, got \(array.dataType)")
        }
        let shape = array.shape.map(\.intValue)
        let strides = array.strides.map(\.intValue)
        guard shape.count >= 3 else {
            throw Self.fault("model output has rank \(shape.count), expected at least 3")
        }
        let rank = shape.count
        let channels = shape[rank - 3], height = shape[rank - 2], width = shape[rank - 1]
        let cStride = strides[rank - 3], hStride = strides[rank - 2], wStride = strides[rank - 1]
        let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
        var values = [Float](repeating: 0, count: channels * height * width)
        var i = 0
        for c in 0 ..< channels {
            for h in 0 ..< height {
                for w in 0 ..< width {
                    values[i] = pointer[c * cStride + h * hStride + w * wStride]
                    i += 1
                }
            }
        }
        return FlatArray(values: values, channels: channels, height: height, width: width)
    }

    private static func fault(_ message: String) -> any Error {
        SheetMusicError.malformedScore(ScoreFault(
            code: "omr.detector", message: "OMR detector: \(message)",
        ))
    }
}
