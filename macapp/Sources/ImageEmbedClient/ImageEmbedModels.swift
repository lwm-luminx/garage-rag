import Foundation

/// What the service says about a resident image embedding model.
public struct ImageEmbedModelInfo: Codable, Equatable, Sendable {
    /// The catalog slug (`siglip2-base-256`), which is also the folder under `models/`.
    public var slug: String
    /// Width of both towers' vectors.
    public var dims: Int
    /// Side of the square the image tower takes, in pixels.
    public var imageSize: Int
    /// Token count the text tower takes; longer queries are cut.
    public var textLength: Int

    enum CodingKeys: String, CodingKey {
        case slug
        case dims
        case imageSize = "image_size"
        case textLength = "text_length"
    }

    public init(slug: String, dims: Int, imageSize: Int, textLength: Int) {
        self.slug = slug
        self.dims = dims
        self.imageSize = imageSize
        self.textLength = textLength
    }
}

public enum ImageEmbedClientError: LocalizedError {
    case serviceUnavailable(String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .serviceUnavailable(let message):
            return "Image embedding service unavailable: \(message)"
        case .invalidResponse(let message):
            return "Invalid response from the image embedding service: \(message)"
        }
    }
}

/// The wire form of a batch of vectors: `count * dims` little-endian Float32 values.
public enum ImageEmbedVectors {
    public static func encode(_ vectors: [[Float]]) -> Data {
        var data = Data(capacity: vectors.reduce(0) { $0 + $1.count } * MemoryLayout<Float>.size)
        for vector in vectors {
            for value in vector {
                var little = value.bitPattern.littleEndian
                withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
            }
        }
        return data
    }

    /// Splits `data` into `count` vectors; nil when its size is not a whole number of them.
    public static func decode(_ data: Data, count: Int) -> [[Float]]? {
        let width = MemoryLayout<Float>.size
        guard count > 0, data.count % width == 0 else { return count == 0 && data.isEmpty ? [] : nil }
        let total = data.count / width
        guard total % count == 0 else { return nil }
        let dims = total / count
        var flat = [Float](repeating: 0, count: total)
        data.withUnsafeBytes { raw in
            for index in 0..<total {
                let bits = raw.loadUnaligned(fromByteOffset: index * width, as: UInt32.self)
                flat[index] = Float(bitPattern: UInt32(littleEndian: bits))
            }
        }
        return (0..<count).map { Array(flat[($0 * dims)..<(($0 + 1) * dims)]) }
    }
}
