import CoreML
import Foundation

/// bge-small-zh-v1.5 端上句向量（0.7.1 阶段二，记忆检索的向量主排）。
/// 模型 = BGEZh.mlpackage（构建期编译成 BGEZh.mlmodelc，int8 量化 22MB，
/// 转换/质量闸门见 tools/vector-spike/ 与 docs/VECTOR-MEMORY-SPIKE.md）；
/// 分词 = 自带 WordPiece（词表资源 BGEZhVocab.txt，与 HF BertTokenizer
/// 同口径：不做小写化、CJK 逐字切开）。
/// 模型/词表缺失或预测失败 → 一律返回 nil，检索路径回退 BM25
/// （`MemoryRetrieval.rankWithVectors` 的降级语义）——记忆功能绝不因
/// 模型问题挂掉。推理 ~4ms/条（M 系列），调用方负责放后台 Task。
nonisolated enum BGEEmbedder {
    /// bge v1.5 官方查询指令：查询侧加前缀，事实侧不加（与验收集一致）。
    static let queryPrefix = "为这个句子生成表示以用于检索相关文章："

    static let maxTokens = 512
    private static let maxWordChars = 100

    /// 查询向量（带官方指令前缀）。
    static func embedQuery(_ query: String) -> [Double]? {
        embed(queryPrefix + query)
    }

    /// 事实向量（原文，不加前缀）。
    static func embedFact(_ content: String) -> [Double]? {
        embed(content)
    }

    /// 通用嵌入：分词 → CoreML 预测 → L2 归一化。任何一步失败 = nil。
    static func embed(_ text: String) -> [Double]? {
        guard let model = model, let vocab = vocab else { return nil }
        let tokens = tokenize(text)
        guard !tokens.isEmpty else { return nil }
        guard let cls = vocab["[CLS]"], let sep = vocab["[SEP]"],
              let pad = vocab["[PAD]"], let unk = vocab["[UNK]"] else { return nil }

        var ids = [cls]
        for piece in tokens.prefix(maxTokens - 2) {
            ids.append(vocab[piece] ?? unk)
        }
        ids.append(sep)
        var mask = [Int32](repeating: 1, count: ids.count)
        ids.append(contentsOf: [Int](repeating: pad, count: maxTokens - ids.count))
        mask.append(contentsOf: [Int32](repeating: 0, count: maxTokens - mask.count))

        guard let idsArray = try? MLMultiArray(shape: [1, NSNumber(value: maxTokens)], dataType: .int32),
              let maskArray = try? MLMultiArray(shape: [1, NSNumber(value: maxTokens)], dataType: .int32)
        else { return nil }
        for i in 0..<maxTokens {
            idsArray[i] = NSNumber(value: ids[i])
            maskArray[i] = NSNumber(value: mask[i])
        }
        guard let features = try? MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: idsArray),
            "attention_mask": MLFeatureValue(multiArray: maskArray),
        ]), let output = try? model.prediction(from: features) else { return nil }

        // 输出名由转换器生成，取第一个 multiArray 输出（CLS 已烘进图）。
        for name in output.featureNames where output.featureValue(for: name)?.multiArrayValue != nil {
            guard let arr = output.featureValue(for: name)?.multiArrayValue else { continue }
            var vec = [Double](repeating: 0, count: arr.count)
            for i in 0..<arr.count { vec[i] = arr[i].doubleValue }
            let norm = vec.reduce(0) { $0 + $1 * $1 }.squareRoot()
            guard norm > 0 else { return nil }
            return vec.map { $0 / norm }
        }
        return nil
    }

    /// 模型可用性（检索路径据此决定向量主排还是 BM25 降级）。
    static var isAvailable: Bool { model != nil && vocab != nil }

    // MARK: - 模型与词表（static let = 线程安全惰性加载；缺失即永久降级，重启再试）

    private static let model: MLModel? = {
        guard let url = Bundle.main.url(forResource: "BGEZh", withExtension: "mlmodelc") else {
            return nil
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        return try? MLModel(contentsOf: url, configuration: config)
    }()

    private static let vocab: [String: Int]? = {
        guard let url = Bundle.main.url(forResource: "BGEZhVocab", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var map: [String: Int] = [:]
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let token = line.hasSuffix("\r") ? String(line.dropLast()) : String(line)
            if !map.keys.contains(token) { map[token] = index }
        }
        return map
    }()

    // MARK: - WordPiece 分词（HF BertTokenizer 口径：do_lower_case=false、CJK 逐字切）

    static func tokenize(_ text: String) -> [String] {
        var cleaned = String()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F:
                continue // 控制字符直接丢
            case 0x09, 0x0A, 0x0D:
                cleaned.unicodeScalars.append(" ") // 制表/换行归一成空格
            default:
                cleaned.unicodeScalars.append(scalar)
            }
        }
        var words: [String] = []
        for rawWord in cleaned.split(separator: " ", omittingEmptySubsequences: true) {
            // CJK 逐字切开（HF tokenize_chinese_chars：每个汉字两侧加空格）
            var piece = ""
            for scalar in rawWord.unicodeScalars {
                if Self.isCJK(scalar) {
                    if !piece.isEmpty { words.append(piece); piece = "" }
                    words.append(String(scalar))
                } else {
                    piece.unicodeScalars.append(scalar)
                }
            }
            if !piece.isEmpty { words.append(piece) }
        }
        var tokens: [String] = []
        for word in words {
            tokens.append(contentsOf: wordPiece(word, vocab: vocab ?? [:]))
        }
        return tokens
    }

    /// HF 的 CJK 判定块（BasicTokenizer._is_chinese_char）。
    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF, 0xF900...0xFAFF, 0x2F800...0x2FA1F:
            return true
        default:
            return false
        }
    }

    /// 贪心最长匹配；任一切片不在词表 → 整词 [UNK]（WordPiece 语义）。
    private static func wordPiece(_ word: String, vocab: [String: Int]) -> [String] {
        let scalars = Array(word.unicodeScalars)
        if scalars.count > maxWordChars { return ["[UNK]"] }
        var pieces: [String] = []
        var start = 0
        while start < scalars.count {
            var end = scalars.count
            var matched: String?
            while start < end {
                var candidate = String(String.UnicodeScalarView(scalars[start..<end]))
                if start > 0 { candidate = "##" + candidate }
                if vocab[candidate] != nil {
                    matched = candidate
                    break
                }
                end -= 1
            }
            guard let piece = matched else { return ["[UNK]"] }
            pieces.append(piece)
            start = end
        }
        return pieces
    }
}
