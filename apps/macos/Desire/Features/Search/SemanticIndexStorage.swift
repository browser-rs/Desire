import Foundation

/// 语义索引的分片落盘（v0.8.22）。每个（来源 × 语言）一对文件：
///
/// - `<source>-<language>.json`：manifest + 条目元数据（提交标记）
/// - `<source>-<language>.vec`：Float32 矩阵（`[count][dim][values…]`，小端）
///
/// **提交顺序**：先原子写 `.vec`，再原子写 `.json`。json 是唯一的有效性
/// 判据——json 缺失/损坏/版本不符 = 该分片作废（下次重建），因此绝不会
/// 出现"json 说有条目、vec 是半截"的错配；崩溃最多丢一个分片的进度，
/// 重开会按内容哈希增量补上，不会重嵌全部。
nonisolated enum SemanticIndexStorage {
    struct Shard: Sendable {
        var manifest: SemanticShardManifest
        var items: [SemanticItem]
        var vectors: [SemanticVectorRecord]
    }

    enum StorageError: Error {
        case vectorCountMismatch
    }

    private struct Payload: Codable {
        var manifest: SemanticShardManifest
        var items: [SemanticItem]
    }

    static var directory: URL {
        DiskStore.directory.appendingPathComponent("semantic", isDirectory: true)
    }

    static func fileURL(_ source: SemanticSource, _ language: SemanticLanguage, ext: String) -> URL {
        directory.appendingPathComponent("\(source.rawValue)-\(language.rawValue).\(ext)")
    }

    /// 读一个分片；任何不一致（版本/来源/语言/维度/长度）都返回 nil。
    static func load(source: SemanticSource, language: SemanticLanguage) -> Shard? {
        guard let data = try? Data(contentsOf: fileURL(source, language, ext: "json")),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        let manifest = payload.manifest
        guard manifest.version == SemanticShardManifest.currentVersion,
              manifest.source == source,
              manifest.language == language,
              manifest.dimension > 0 else { return nil }
        guard let blob = try? Data(contentsOf: fileURL(source, language, ext: "vec")),
              let values = decode(blob, expectedItems: payload.items.count,
                                  expectedDimension: manifest.dimension) else { return nil }
        var vectors: [SemanticVectorRecord] = []
        vectors.reserveCapacity(payload.items.count)
        for (index, item) in payload.items.enumerated() {
            let start = index * manifest.dimension
            let slice = Array(values[start..<(start + manifest.dimension)])
            vectors.append(SemanticVectorRecord(id: item.id,
                                                contentHash: item.contentHash,
                                                vector: slice))
        }
        return Shard(manifest: manifest, items: payload.items, vectors: vectors)
    }

    static func save(_ shard: Shard) throws {
        guard shard.vectors.count == shard.items.count else {
            throw StorageError.vectorCountMismatch
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var blob = Data()
        blob.append(littleEndianBytes(UInt32(shard.items.count)))
        blob.append(littleEndianBytes(UInt32(shard.manifest.dimension)))
        blob.reserveCapacity(8 + shard.vectors.count * shard.manifest.dimension * 4)
        for record in shard.vectors {
            for value in record.vector {
                blob.append(littleEndianBytes(value.bitPattern))
            }
        }
        try blob.write(to: fileURL(shard.manifest.source, shard.manifest.language, ext: "vec"),
                       options: .atomic)

        let payload = Payload(manifest: shard.manifest, items: shard.items)
        let data = try JSONEncoder().encode(payload)
        try data.write(to: fileURL(shard.manifest.source, shard.manifest.language, ext: "json"),
                       options: .atomic)
    }

    static func remove(source: SemanticSource) {
        for language in SemanticLanguage.allCases {
            remove(source: source, language: language)
        }
    }

    static func remove(source: SemanticSource, language: SemanticLanguage) {
        let fm = FileManager.default
        try? fm.removeItem(at: fileURL(source, language, ext: "json"))
        try? fm.removeItem(at: fileURL(source, language, ext: "vec"))
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// 分片文件的字节数（用于状态面板；文件不存在按 0 算）。
    static func bytes(source: SemanticSource, language: SemanticLanguage) -> Int {
        let fm = FileManager.default
        var total = 0
        for ext in ["json", "vec"] {
            let path = fileURL(source, language, ext: ext).path
            if let attrs = try? fm.attributesOfItem(atPath: path),
               let size = attrs[.size] as? Int {
                total += size
            }
        }
        return total
    }

    // MARK: - 二进制编解码

    private static func littleEndianBytes(_ value: UInt32) -> Data {
        var little = value.littleEndian
        return withUnsafeBytes(of: &little) { Data($0) }
    }

    private static func decode(_ data: Data, expectedItems: Int,
                               expectedDimension: Int) -> [Float]? {
        guard data.count >= 8 else { return nil }
        let count = Int(UInt32(littleEndian: data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
        }))
        let dimension = Int(UInt32(littleEndian: data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
        }))
        guard count == expectedItems,
              dimension == expectedDimension,
              data.count == 8 + count * dimension * 4 else { return nil }
        var values: [Float] = []
        values.reserveCapacity(count * dimension)
        data.withUnsafeBytes { raw in
            for index in 0..<(count * dimension) {
                let bits = raw.loadUnaligned(fromByteOffset: 8 + index * 4, as: UInt32.self)
                values.append(Float(bitPattern: UInt32(littleEndian: bits)))
            }
        }
        return values
    }
}
