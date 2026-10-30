import Foundation

/// CRC-32（ISO-HDLC，zip/以太网同款多项式 0xEDB88320）——纯逻辑。
nonisolated enum CRC32Core {
    private static let table: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) != 0 ? (value >> 1) ^ 0xEDB88320 : value >> 1
            }
            return value
        }
    }()

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }

    static func hex(_ data: Data) -> String {
        String(format: "%08x", crc32(data))
    }
}
