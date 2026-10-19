import Foundation

/// 社区模板拉取与校验（v0.7.24）：索引/板文件都走网络，解码 + schema 校验与
/// 本地 .board 导入同一口径（过新拒绝、无效拒绝）。纯网络层，不做 UI。
enum BoardGalleryService {
    enum GalleryError: LocalizedError {
        case unreachable(String)
        case badIndex
        case unknownBoard(String)
        case invalidBoard
        case schemaTooNew(String)
        var errorDescription: String? {
            switch self {
            case .unreachable(let detail):
                String(localized: "Community unreachable: \(detail)")
            case .badIndex:
                String(localized: "The community index is invalid or in an unknown version.")
            case .unknownBoard(let id):
                String(localized: "No such template: \(id)")
            case .invalidBoard:
                String(localized: "Not a valid .board file.")
            case .schemaTooNew(let version):
                String(localized: "Schema \(version) is too new — update Desire and retry.")
            }
        }
    }

    static func fetchIndex(base: String = BoardGallery.defaultBaseURL) async throws -> [BoardGallery.Board] {
        guard let url = URL(string: "index.json", relativeTo: URL(string: base))?.absoluteURL else {
            throw GalleryError.badIndex
        }
        let data = try await get(url)
        guard let index = BoardGallery.parseIndex(data) else { throw GalleryError.badIndex }
        return index.boards
    }

    static func fetchBoard(_ board: BoardGallery.Board, base: String = BoardGallery.defaultBaseURL) async throws -> WhiteboardSpec {
        guard let url = BoardGallery.resolveFileURL(board.file, base: base) else {
            throw GalleryError.invalidBoard
        }
        let data = try await get(url)
        guard let spec = try? JSONDecoder().decode(WhiteboardSpec.self, from: data) else {
            throw GalleryError.invalidBoard
        }
        if let version = spec.schemaVersion, version != WhiteboardSpec.boardSchemaVersion {
            throw GalleryError.schemaTooNew(version)
        }
        return spec
    }

    private static func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GalleryError.unreachable("no HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw GalleryError.unreachable("HTTP \(http.statusCode)")
        }
        return data
    }
}
