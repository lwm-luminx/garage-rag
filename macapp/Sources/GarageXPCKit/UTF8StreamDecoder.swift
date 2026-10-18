import Foundation

/// Decodes UTF-8 arriving in arbitrary chunks, such as pipe reads. A chunk can end partway through a
/// multibyte character; decoding each chunk on its own would turn both halves into U+FFFD. The
/// incomplete tail is held back and completed by the next chunk.
public struct UTF8StreamDecoder {
    private var pending = Data()

    public init() {}

    /// The text in `data` up to its last complete character, preceded by anything held back from the
    /// previous call. Malformed bytes still decode as U+FFFD.
    public mutating func decode(_ data: Data) -> String {
        var bytes = pending
        bytes.append(data)
        let cut = Self.completePrefixLength(of: bytes)
        pending = bytes.subdata(in: (bytes.startIndex + cut)..<bytes.endIndex)
        return String(decoding: bytes.prefix(cut), as: UTF8.self)
    }

    /// Whatever is still held back, decoded as is (for the end of a stream).
    public mutating func flush() -> String {
        defer { pending.removeAll() }
        return String(decoding: pending, as: UTF8.self)
    }

    /// The length of `bytes` without a trailing, incomplete multibyte sequence.
    static func completePrefixLength(of bytes: Data) -> Int {
        let count = bytes.count
        var offset = count - 1
        // A sequence is at most 4 bytes, so its lead byte is within the last 4.
        while offset >= 0, offset >= count - 4 {
            let byte = bytes[bytes.startIndex + offset]
            if byte & 0b1100_0000 == 0b1000_0000 {
                offset -= 1
                continue
            }
            let length: Int
            switch byte {
            case 0b1111_0000...0b1111_0111: length = 4
            case 0b1110_0000...0b1110_1111: length = 3
            case 0b1100_0000...0b1101_1111: length = 2
            default: length = 1
            }
            return count - offset < length ? offset : count
        }
        // Only continuation bytes at the end: malformed, not incomplete. Decode it all.
        return count
    }
}
