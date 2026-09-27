import Foundation

public enum BPETokenizerError: LocalizedError {
    case unreadable(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let detail): return "tokenizer.json could not be read: \(detail)"
        case .unsupported(let detail): return "tokenizer.json is not a tokenizer this build can run: \(detail)"
        }
    }
}

/// The text tower's tokenizer, read from a Hugging Face `tokenizer.json`.
///
/// Covers the SentencePiece-style BPE the SigLIP 2 text tower uses (the Gemma tokenizer): no
/// pre-tokenizer, a normalizer that turns spaces into `▁`, merges applied by rank over the whole
/// string, and byte fallback (`<0x0A>`) for characters the vocabulary lacks. `encode` returns the
/// ids the way SigLIP 2 wants them: lowercased when the model says so, cut to `length - 1`, an
/// end-of-sequence id appended, and padded to `length` with the pad id.
public final class BPETokenizer: @unchecked Sendable {
    private struct Pair: Hashable {
        let left: String
        let right: String
    }

    private enum Normalizer {
        case replace(pattern: String, content: String)
        case lowercase
        case prepend(String)
    }

    private let vocab: [String: Int32]
    private let ranks: [Pair: Int]
    private let normalizers: [Normalizer]
    private let byteFallback: Bool
    private let unknownId: Int32?
    public let padId: Int32
    public let eosId: Int32
    public let bosId: Int32?
    public let vocabularySize: Int

    public convenience init(contentsOf url: URL) throws {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw BPETokenizerError.unreadable(error.localizedDescription)
        }
        try self.init(data: data)
    }

    public init(data: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BPETokenizerError.unreadable("not a JSON object")
        }
        guard let model = object["model"] as? [String: Any] else {
            throw BPETokenizerError.unsupported("no model section")
        }
        let type = (model["type"] as? String) ?? ""
        guard type == "BPE" else {
            throw BPETokenizerError.unsupported("model type \(type.isEmpty ? "missing" : type); only BPE is supported")
        }
        guard let rawVocab = model["vocab"] as? [String: Any] else {
            throw BPETokenizerError.unsupported("no vocab")
        }
        var vocab: [String: Int32] = [:]
        vocab.reserveCapacity(rawVocab.count)
        for (token, id) in rawVocab {
            if let number = id as? NSNumber {
                vocab[token] = number.int32Value
            }
        }
        // Special tokens listed only under added_tokens (some exports keep them out of vocab).
        for entry in object["added_tokens"] as? [[String: Any]] ?? [] {
            if let content = entry["content"] as? String, let id = (entry["id"] as? NSNumber)?.int32Value, vocab[content] == nil {
                vocab[content] = id
            }
        }

        var ranks: [Pair: Int] = [:]
        if let merges = model["merges"] as? [Any] {
            ranks.reserveCapacity(merges.count)
            for (rank, merge) in merges.enumerated() {
                if let pair = merge as? [String], pair.count == 2 {
                    ranks[Pair(left: pair[0], right: pair[1])] = rank
                } else if let line = merge as? String {
                    // "left right": the token halves never contain spaces (spaces became ▁).
                    let halves = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
                    if halves.count == 2 {
                        ranks[Pair(left: String(halves[0]), right: String(halves[1]))] = rank
                    }
                }
            }
        }

        self.vocab = vocab
        self.ranks = ranks
        self.normalizers = Self.parseNormalizer(object["normalizer"])
        self.byteFallback = (model["byte_fallback"] as? Bool) ?? false
        self.vocabularySize = vocab.count
        let unk = (model["unk_token"] as? String).flatMap { vocab[$0] }
        self.unknownId = unk ?? vocab["<unk>"]
        self.padId = vocab["<pad>"] ?? 0
        guard let eos = vocab["<eos>"] ?? vocab["</s>"] ?? vocab["<|endoftext|>"] else {
            throw BPETokenizerError.unsupported("no end-of-sequence token (<eos>, </s> or <|endoftext|>)")
        }
        self.eosId = eos
        self.bosId = vocab["<bos>"] ?? vocab["<s>"]
    }

    private static func parseNormalizer(_ value: Any?) -> [Normalizer] {
        guard let object = value as? [String: Any], let type = object["type"] as? String else { return [] }
        switch type {
        case "Sequence":
            return (object["normalizers"] as? [Any] ?? []).flatMap { parseNormalizer($0) }
        case "Replace":
            if let pattern = (object["pattern"] as? [String: Any])?["String"] as? String, let content = object["content"] as? String {
                return [.replace(pattern: pattern, content: content)]
            }
            return []
        case "Lowercase":
            return [.lowercase]
        case "Prepend":
            if let prepend = object["prepend"] as? String {
                return [.prepend(prepend)]
            }
            return []
        default:
            // NFC/NFKC and friends: the vocabularies at hand are built on unnormalized text, and a
            // query is short; applying nothing is closer than guessing.
            return []
        }
    }

    /// The raw token ids of `text` (no special tokens).
    public func tokenize(_ text: String, lowercase: Bool) -> [Int32] {
        var normalized = lowercase ? text.lowercased() : text
        for normalizer in normalizers {
            switch normalizer {
            case .replace(let pattern, let content):
                normalized = normalized.replacingOccurrences(of: pattern, with: content)
            case .lowercase:
                normalized = normalized.lowercased()
            case .prepend(let prefix):
                if !normalized.hasPrefix(prefix) {
                    normalized = prefix + normalized
                }
            }
        }
        if normalized.isEmpty { return [] }

        // Start from characters (unicode scalars, as SentencePiece does), with byte fallback for
        // any the vocabulary lacks, then merge pairs by rank until none can be merged.
        var symbols: [String] = []
        symbols.reserveCapacity(normalized.unicodeScalars.count)
        for scalar in normalized.unicodeScalars {
            let piece = String(scalar)
            if vocab[piece] != nil || !byteFallback {
                symbols.append(piece)
            } else {
                for byte in piece.utf8 {
                    symbols.append(String(format: "<0x%02X>", byte))
                }
            }
        }

        while symbols.count > 1 {
            var best: (rank: Int, index: Int)?
            for index in 0..<(symbols.count - 1) {
                if let rank = ranks[Pair(left: symbols[index], right: symbols[index + 1])], best == nil || rank < best!.rank {
                    best = (rank, index)
                }
            }
            guard let found = best else { break }
            let merged = symbols[found.index] + symbols[found.index + 1]
            var next: [String] = []
            next.reserveCapacity(symbols.count)
            var index = 0
            while index < symbols.count {
                if index < symbols.count - 1, symbols[index] == symbols[found.index], symbols[index + 1] == symbols[found.index + 1] {
                    next.append(merged)
                    index += 2
                } else {
                    next.append(symbols[index])
                    index += 1
                }
            }
            symbols = next
        }

        var ids: [Int32] = []
        ids.reserveCapacity(symbols.count)
        for symbol in symbols {
            if let id = vocab[symbol] {
                ids.append(id)
            } else if let unknownId {
                ids.append(unknownId)
            }
        }
        return ids
    }

    /// `text` as the text tower takes it: ids cut to `length - 1`, `<eos>` appended, padded to `length`.
    public func encode(_ text: String, length: Int, lowercase: Bool) -> [Int32] {
        var ids = Array(tokenize(text, lowercase: lowercase).prefix(max(length - 1, 0)))
        if ids.count < length {
            ids.append(eosId)
        }
        while ids.count < length {
            ids.append(padId)
        }
        return Array(ids.prefix(length))
    }
}
