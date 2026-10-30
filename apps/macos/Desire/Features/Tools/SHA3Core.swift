import CryptoKit
import Foundation

/// SHA3 哈希——纯逻辑。
nonisolated enum SHA3Core {
    static func hex(_ data: Data, variant: Variant) -> String {
        switch variant {
        case .sha3_256:
            return SHA3_256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        case .sha3_512:
            return SHA3_512.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }

    enum Variant: String, CaseIterable, Sendable {
        case sha3_256 = "SHA3-256"
        case sha3_512 = "SHA3-512"
    }
}
