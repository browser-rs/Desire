import Foundation

/// Fetches the available model list from an OpenAI-compatible API's
/// `GET /models` endpoint. Used by the settings UI to populate a model
/// picker instead of relying on hardcoded presets.
enum ModelListFetcher {
    struct ModelEntry: Identifiable, Equatable {
        let id: String
    }

    /// Queries `GET {base}/models` for the available model IDs.
    /// `endpoint` is the full chat-completions / messages URL (e.g. `…/v1/chat/completions`);
    /// the base URL is derived by stripping the tail segment.
    /// Anthropic 格式走 `x-api-key` + `anthropic-version` 头（响应 `data[].id` 形状相同）。
    static func fetch(endpoint: String, apiKey: String, format: AIProviderProfile.APIFormat = .openai) async throws -> [String] {
        var base = endpoint
            .replacingOccurrences(of: "/chat/completions", with: "")
            .replacingOccurrences(of: "/completions", with: "")
        if format == .anthropic {
            if base.hasSuffix("/messages") {
                base = String(base.dropLast("/messages".count))
            }
            if !base.hasSuffix("/v1") {
                base += "/v1"
            }
        }
        guard let url = URL(string: base + "/models") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        if !apiKey.isEmpty {
            if format == .anthropic {
                request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            } else {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
        }
        // OpenCode Go session routing header.
        if base.contains("opencode") {
            let sid = UserDefaults.standard.string(forKey: "aiOpencodeSessionID")
                ?? UUID().uuidString
            UserDefaults.standard.set(sid, forKey: "aiOpencodeSessionID")
            request.setValue(sid, forHTTPHeaderField: "x-opencode-session")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let modelList = json["data"] as? [[String: Any]] else {
            throw URLError(.cannotParseResponse)
        }
        let ids = modelList.compactMap { $0["id"] as? String }.sorted()
        return ids
    }
}
