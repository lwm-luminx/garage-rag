import CoreGraphics
import CoreML
import Foundation
import ImageEmbedClient
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag", category: "CoreMLImageEmbedder")

public enum CoreMLImageEmbedderError: LocalizedError {
    case noInput(String)
    case noOutput(String)
    case unexpectedInput(String)
    case unexpectedOutput(String)
    case widthMismatch(image: Int, text: Int)

    public var errorDescription: String? {
        switch self {
        case .noInput(let model): return "\(model) declares no input"
        case .noOutput(let model): return "\(model) declares no output"
        case .unexpectedInput(let detail): return "unexpected model input: \(detail)"
        case .unexpectedOutput(let detail): return "unexpected model output: \(detail)"
        case .widthMismatch(let image, let text):
            return "the image tower emits \(image)-wide vectors but the text tower \(text)-wide; they are not one model"
        }
    }
}

/// One image embedding model, resident: its two Core ML towers and tokenizer.
///
/// The input and output feature of each tower are whatever the package declares (it has one of
/// each), so a conversion that names them `pixel_values` / `image_embeds` and one that names them
/// `image` / `embedding` both run. Vectors are L2-normalized on the way out; cosine distance is
/// what the catalog declares for these models.
public final class CoreMLImageEmbedder: @unchecked Sendable {
    public let spec: ImageModelSpec
    public let info: ImageEmbedModelInfo
    private let imageModel: MLModel
    private let textModel: MLModel
    private let imageInputName: String
    private let imageOutputName: String
    private let textInputName: String
    private let textOutputName: String
    private let imageInputIsImage: Bool
    private let tokenizer: BPETokenizer
    private let preprocessor: ImagePreprocessor
    /// Core ML models are not documented as safe for concurrent prediction; one at a time.
    private let lock = NSLock()

    public init(spec: ImageModelSpec, imagePackage: URL, textPackage: URL, tokenizer tokenizerURL: URL) throws {
        self.spec = spec
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        imageModel = try Self.load(imagePackage, configuration: configuration)
        textModel = try Self.load(textPackage, configuration: configuration)
        tokenizer = try BPETokenizer(contentsOf: tokenizerURL)

        guard let imageInput = imageModel.modelDescription.inputDescriptionsByName.first else {
            throw CoreMLImageEmbedderError.noInput(imagePackage.lastPathComponent)
        }
        guard let imageOutput = imageModel.modelDescription.outputDescriptionsByName.first else {
            throw CoreMLImageEmbedderError.noOutput(imagePackage.lastPathComponent)
        }
        guard let textInput = textModel.modelDescription.inputDescriptionsByName.first else {
            throw CoreMLImageEmbedderError.noInput(textPackage.lastPathComponent)
        }
        guard let textOutput = textModel.modelDescription.outputDescriptionsByName.first else {
            throw CoreMLImageEmbedderError.noOutput(textPackage.lastPathComponent)
        }
        imageInputName = imageInput.key
        imageOutputName = imageOutput.key
        textInputName = textInput.key
        textOutputName = textOutput.key

        // The image side: a [1, 3, H, W] array or an image feature; the side of the square comes from it.
        let imageSize: Int
        switch imageInput.value.type {
        case .multiArray:
            imageInputIsImage = false
            let shape = imageInput.value.multiArrayConstraint?.shape.map(\.intValue) ?? []
            guard shape.count == 4, shape[1] == 3, shape[2] == shape[3], shape[2] > 0 else {
                throw CoreMLImageEmbedderError.unexpectedInput("\(imageInput.key) has shape \(shape); expected [1, 3, N, N]")
            }
            imageSize = shape[2]
        case .image:
            imageInputIsImage = true
            let constraint = imageInput.value.imageConstraint
            imageSize = constraint.map { Int(min($0.pixelsWide, $0.pixelsHigh)) } ?? (spec.imageSize ?? 224)
        default:
            throw CoreMLImageEmbedderError.unexpectedInput("\(imageInput.key) is neither an array nor an image")
        }
        preprocessor = ImagePreprocessor(size: imageSize, mean: spec.imageMean, std: spec.imageStd)

        // The text side: a [1, L] array of token ids.
        guard textInput.value.type == .multiArray else {
            throw CoreMLImageEmbedderError.unexpectedInput("\(textInput.key) is not an array of token ids")
        }
        let textShape = textInput.value.multiArrayConstraint?.shape.map(\.intValue) ?? []
        let textLength = textShape.last.flatMap { $0 > 0 ? $0 : nil } ?? spec.textLength ?? 64

        let imageDims = Self.width(of: imageOutput.value) ?? spec.dims ?? 0
        let textDims = Self.width(of: textOutput.value) ?? spec.dims ?? 0
        if imageDims > 0, textDims > 0, imageDims != textDims {
            throw CoreMLImageEmbedderError.widthMismatch(image: imageDims, text: textDims)
        }
        info = ImageEmbedModelInfo(slug: spec.slug, dims: max(imageDims, textDims), imageSize: imageSize, textLength: textLength)
        logger.info("\(spec.slug, privacy: .public) loaded: \(imageSize, privacy: .public) px, \(textLength, privacy: .public) tokens, \(self.info.dims, privacy: .public) dims")
    }

    /// The last dimension of an output array constraint, when it is fixed.
    private static func width(of feature: MLFeatureDescription) -> Int? {
        guard let shape = feature.multiArrayConstraint?.shape.map(\.intValue), let last = shape.last, last > 0 else { return nil }
        return last
    }

    /// Loads a package, compiling it once into `.compiled/` beside it (an `.mlmodelc` loads as is).
    static func load(_ url: URL, configuration: MLModelConfiguration) throws -> MLModel {
        if url.pathExtension == "mlmodelc" {
            return try MLModel(contentsOf: url, configuration: configuration)
        }
        let compiledDirectory = url.deletingLastPathComponent().appendingPathComponent(".compiled", isDirectory: true)
        let compiled = compiledDirectory.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".mlmodelc")
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: compiled.path), isFresh(compiled, against: url) {
            return try MLModel(contentsOf: compiled, configuration: configuration)
        }
        let temporary = try MLModel.compileModel(at: url)
        try fileManager.createDirectory(at: compiledDirectory, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: compiled.path) {
            try fileManager.removeItem(at: compiled)
        }
        try fileManager.moveItem(at: temporary, to: compiled)
        return try MLModel(contentsOf: compiled, configuration: configuration)
    }

    /// Whether the compiled copy is newer than the package's specification.
    private static func isFresh(_ compiled: URL, against package: URL) -> Bool {
        let specification = package.appendingPathComponent("Data/com.apple.CoreML/model.mlmodel")
        guard let compiledDate = modificationDate(compiled) else { return false }
        guard let sourceDate = modificationDate(specification) ?? modificationDate(package) else { return true }
        return compiledDate >= sourceDate
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    // MARK: - Embedding

    public func embedImages(_ images: [Data]) throws -> [[Float]] {
        try images.map { data in
            let value: MLFeatureValue
            if imageInputIsImage {
                let image = try ImagePreprocessor.decode(data)
                guard let constraint = imageModel.modelDescription.inputDescriptionsByName[imageInputName]?.imageConstraint else {
                    throw CoreMLImageEmbedderError.unexpectedInput("\(imageInputName) has no image constraint")
                }
                value = try MLFeatureValue(cgImage: image, constraint: constraint, options: [.cropAndScale: NSNumber(value: scaleFillOption)])
            } else {
                value = MLFeatureValue(multiArray: try preprocessor.multiArray(for: data))
            }
            return try predict(imageModel, input: [imageInputName: value], output: imageOutputName)
        }
    }

    public func embedTexts(_ texts: [String]) throws -> [[Float]] {
        try texts.map { text in
            let ids = tokenizer.encode(text, length: info.textLength, lowercase: spec.textLowercase)
            let array = try MLMultiArray(shape: [1, NSNumber(value: ids.count)], dataType: .int32)
            let pointer = array.dataPointer.bindMemory(to: Int32.self, capacity: ids.count)
            for (index, id) in ids.enumerated() {
                pointer[index] = id
            }
            return try predict(textModel, input: [textInputName: MLFeatureValue(multiArray: array)], output: textOutputName)
        }
    }

    private func predict(_ model: MLModel, input: [String: MLFeatureValue], output: String) throws -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let provider = try MLDictionaryFeatureProvider(dictionary: input)
        let result = try model.prediction(from: provider)
        guard let array = result.featureValue(for: output)?.multiArrayValue else {
            throw CoreMLImageEmbedderError.unexpectedOutput("\(output) is not an array")
        }
        return Self.normalized(Self.floats(array))
    }

    static func floats(_ array: MLMultiArray) -> [Float] {
        let count = array.count
        var values = [Float](repeating: 0, count: count)
        switch array.dataType {
        case .float32:
            let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: count)
            for index in 0..<count { values[index] = pointer[index] }
        case .double:
            let pointer = array.dataPointer.bindMemory(to: Double.self, capacity: count)
            for index in 0..<count { values[index] = Float(pointer[index]) }
        default:
            for index in 0..<count { values[index] = array[index].floatValue }
        }
        return values
    }

    static func normalized(_ vector: [Float]) -> [Float] {
        let norm = vector.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }
}

// VNImageCropAndScaleOption.scaleFill's raw value, so the engine does not link Vision for one constant.
private let scaleFillOption: UInt = 2
