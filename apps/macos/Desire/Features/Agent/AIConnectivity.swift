import Foundation

/// 设置页"测试连接"的统一探针（ARCH-3 收口）——此前在
/// `AgentSettingsSection` 里两份手写 URLRequest 各自漂移（一份带鉴权头 +
/// 服务器错误回显，一份不带），新引擎接入时第三份只会更远。
/// 网络请求归服务层；View 只拿状态字符串渲染。
///
/// 两个探针的分工：
/// - `probe`（Ollama 本地）：最小请求读完整响应——本地服务快，无需流式。
/// - `probeChat`（云端服务）：**贴近真实聊天请求**——流式 + 档案自定义头 +
///   按线协议补全端点，服务器送出第一行即判定连通。曾实测（AMD Radeon
///   网关）：聊天（流式）秒通，旧探针 `stream:false` 要等整个生成跑完，
///   15s 必假超时——探针必须量"能不能聊"，不是"能不能等一个非流式响应"。
nonisolated enum AIConnectivity {

    /// Ollama 本地探针：发一条最小 chat 请求探测可达性。返回状态文本
    /// （"Connected ✓" / "HTTP 401: …" / "Failed: …"）。
    static func probe(
        endpoint: String,
        model: String,
        apiKey: String?,
        timeout: TimeInterval
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
        // 不带 stream 字段（Ollama 默认非流式，读完整 JSON）。
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": "Respond with 'ok'"]],
            "max_tokens": 10,
        ]
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

    /// 云端服务探针：与真实聊天同形态（流式；OpenAI 兼容走 Bearer +
    /// `/chat/completions`，Anthropic 走 `x-api-key` + `/v1/messages`），
    /// 并携带档案的自定义请求头。判定口径是"服务器开始回包"：
    /// HTTP 200 后收到第一行即 Connected；非 200 回显错误原文。
    /// 这样生成慢/非流式路径排队的网关不会被误报超时——真不可达
    /// （连接失败、超时收不到任何字节）仍然如实报 Failed。
    static func probeChat(
        endpoint: String,
        model: String,
        apiKey: String?,
        timeout: TimeInterval,
        opencodeSessionHeader: Bool = false,
        extraHeaders: [String: String] = [:],
        anthropic: Bool = false
    ) async -> String {
        // 端点宽容补全，与两条聊天路径（AgentService / AnthropicProvider）同一 DX。
        let urlStr: String
        if anthropic {
            if endpoint.hasSuffix("/messages") {
                urlStr = endpoint
            } else {
                urlStr = endpoint.hasSuffix("/v1") ? endpoint + "/messages" : endpoint + "/v1/messages"
            }
        } else {
            urlStr = endpoint.hasSuffix("/chat/completions") ? endpoint : endpoint + "/chat/completions"
        }
        guard let url = URL(string: urlStr) else { return "Invalid endpoint" }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": "Respond with 'ok'"]],
            "stream": true,
            "max_tokens": 10,
        ]
        if anthropic {
            // Anthropic Messages：key 走 x-api-key，max_tokens 必填。
            if let apiKey, !apiKey.isEmpty {
                req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            }
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else if let apiKey, !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        if opencodeSessionHeader {
            let sid = UserDefaults.standard.string(forKey: "aiOpencodeSessionID") ?? UUID().uuidString
            UserDefaults.standard.set(sid, forKey: "aiOpencodeSessionID")
            req.setValue(sid, forHTTPHeaderField: "x-opencode-session")
        }
        // 档案自定义请求头，过滤规则与聊天路径一致：空名跳过，
        // 不覆盖鉴权/类型/版本头（Anthropic 侧多挡 x-api-key / anthropic-version）。
        for (name, value) in extraHeaders {
            let header = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !header.isEmpty else { continue }
            let lower = header.lowercased()
            if lower == "authorization" || lower == "content-type" { continue }
            if anthropic, lower == "x-api-key" || lower == "anthropic-version" { continue }
            req.setValue(value, forHTTPHeaderField: header)
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: req)
            guard let http = response as? HTTPURLResponse else { return "Failed: invalid response" }
            if http.statusCode != 200 {
                // 错误原文回显；body 读不到（空/断流）也要把状态码报出去。
                var data = Data()
                do {
                    for try await b in bytes {
                        data.append(b)
                        if data.count >= 400 { break }
                    }
                } catch {}
                let text = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
                return "HTTP \(http.statusCode): \(text)"
            }
            // 流式 200：收到第一行就算通（bytes 离开作用域，底层传输随之终止），
            // 不等整个生成——判定的是"能不能聊"，不是"生成要多久"。
            var iterator = bytes.lines.makeAsyncIterator()
            _ = try await iterator.next()
            return "Connected ✓"
        } catch {
            return "Failed: \(error.localizedDescription)"
        }
    }
}
