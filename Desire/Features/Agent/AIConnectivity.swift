import Foundation

/// 设置页"测试连接"的统一探针（ARCH-3 收口）——此前在
/// `AgentSettingsSection` 里两份手写 URLRequest 各自漂移（一份带鉴权头 +
/// 服务器错误回显，一份不带），新引擎接入时第三份只会更远。
/// 网络请求归服务层；View 只拿状态字符串渲染。
nonisolated enum AIConnectivity {

    /// 发一条最小 chat 请求探测端点可达性。返回状态文本
    /// （"Connected ✓" / "HTTP 401: …" / "Failed: …"），与各测试按钮既有文案一致。
    static func probe(
        endpoint: String,
        model: String,
        apiKey: String?,
        timeout: TimeInterval,
        opencodeSessionHeader: Bool = false,
        includeStreamFalse: Bool = true
    ) async -> String {
        let urlStr = endpoint.hasSuffix("/chat/completions") ? endpoint : endpoint + "/chat/completions"
        guard let url = URL(string: urlStr) else { return "Invalid endpoint" }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        if opencodeSessionHeader {
            let sid = UserDefaults.standard.string(forKey: "aiOpencodeSessionID") ?? UUID().uuidString
            UserDefaults.standard.set(sid, forKey: "aiOpencodeSessionID")
            req.setValue(sid, forHTTPHeaderField: "x-opencode-session")
        }
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": "Respond with 'ok'"]],
            "max_tokens": 10,
        ]
        if includeStreamFalse { body["stream"] = false }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                return "Connected ✓"
            }
            if let http = response as? HTTPURLResponse {
                // 服务器错误原文回显（用户才知道为什么被拒）。
                return "HTTP \(http.statusCode): \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")"
            }
            return "Failed: invalid response"
        } catch {
            return "Failed: \(error.localizedDescription)"
        }
    }
}
