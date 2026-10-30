import Foundation

/// UUID v7（时间有序）生成——纯逻辑（48 位毫秒时间戳 + 随机位）。
nonisolated enum UUIDV7Core {
    static func generate(now: Date = Date(), random: (Int) -> [UInt8] = { count in
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) }
    }) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        let milliseconds = UInt64(max(0, (now.timeIntervalSince1970 * 1000).rounded()))
        for offset in 0..<6 {
            bytes[offset] = UInt8((milliseconds >> UInt64(8 * (5 - offset))) & 0xFF)
        }
        let randomBits = random(10)
        for offset in 0..<10 {
            bytes[6 + offset] = randomBits[offset]
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x70   // version 7
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // variant 10
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// 从 UUID 提取毫秒时间戳（非 v7 返回 nil）。
    static func timestamp(of uuid: UUID) -> UInt64? {
        // withUnsafeBytes 按写入顺序给出字节（b0 在前）——无需翻转。
        let bytes = withUnsafeBytes(of: uuid.uuid) { buffer in
            Array(buffer)
        }
        guard bytes[6] >> 4 == 7 else { return nil }
        var milliseconds: UInt64 = 0
        for offset in 0..<6 {
            milliseconds = milliseconds << 8 | UInt64(bytes[offset])
        }
        return milliseconds
    }
}
