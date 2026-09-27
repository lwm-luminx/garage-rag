import CoreGraphics
import CoreML
import Foundation
import ImageIO

public enum ImagePreprocessorError: LocalizedError {
    case undecodable
    case drawingFailed

    public var errorDescription: String? {
        switch self {
        case .undecodable: return "the image could not be decoded"
        case .drawingFailed: return "the image could not be drawn into the model's input"
        }
    }
}

/// Turns an encoded image (JPEG, PNG, HEIC, TIFF, WebP, ... whatever ImageIO reads) into the image
/// tower's input: a square of `size` pixels, resized without keeping the aspect ratio as SigLIP's
/// processor does, channels first, `(pixel / 255 - mean) / std`.
public struct ImagePreprocessor: Sendable {
    public let size: Int
    public let mean: [Float]
    public let std: [Float]

    public init(size: Int, mean: [Float], std: [Float]) {
        self.size = size
        self.mean = mean.count == 3 ? mean : ImageModelSpec.defaultImageMean
        self.std = std.count == 3 ? std : ImageModelSpec.defaultImageStd
    }

    /// Decodes `data` with its EXIF orientation applied. Large photos are decoded at a reduced
    /// size first (at most `maxPixelSize` on the long side), which is what a 256-pixel model sees anyway.
    public static func decode(_ data: Data, maxPixelSize: Int = 1024) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ImagePreprocessorError.undecodable
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return image
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImagePreprocessorError.undecodable
        }
        return image
    }

    /// `image` squashed to `size` x `size`, as packed RGBA bytes.
    public func rgba(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: size * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            // Flatten transparency onto white, as PIL's RGB conversion of a PNG does.
            context.setFillColor(CGColor(colorSpace: colorSpace, components: [1, 1, 1, 1]) ?? CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard drawn else { throw ImagePreprocessorError.drawingFailed }
        return pixels
    }

    /// The model input for `data`: a `[1, 3, size, size]` Float32 array.
    public func multiArray(for data: Data) throws -> MLMultiArray {
        let image = try Self.decode(data)
        let pixels = try rgba(image)
        let array = try MLMultiArray(shape: [1, 3, NSNumber(value: size), NSNumber(value: size)], dataType: .float32)
        let plane = size * size
        let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: 3 * plane)
        for index in 0..<plane {
            let base = index * 4
            for channel in 0..<3 {
                let value = Float(pixels[base + channel]) / 255
                pointer[channel * plane + index] = (value - mean[channel]) / std[channel]
            }
        }
        return array
    }
}
