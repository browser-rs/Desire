import Foundation

/// 模型服务档案（AIProviderProfile）的自动化入口。
///
/// 与设置页是同一份数据：新建/激活/删除/写 Key 都直接改 `AgentPreferenceStore`，
/// 所以脚本化的验证与手工操作看到的结果一致。
extension AutomationServer {

    static func aiProfiles() -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        let store = app.aiPreference
        return [
            "active": store.activeProfileID?.uuidString ?? store.activeProfile?.id.uuidString ?? "",
            "providerKind": store.providerKind.rawValue,
            "profiles": store.profiles.map { profile -> [String: Any] in
                [
                    "id": profile.id.uuidString,
                    "name": profile.name,
                    "endpoint": profile.endpoint,
                    "model": profile.model,
                    "models": profile.modelList,
                    "headers": profile.headers,
                    "builtin": profile.isBuiltin,
                    "active": store.activeProfileID == profile.id,
                    "hasKey": store.loadAPIKey(profileID: profile.id) != nil,
                ]
            },
        ]
    }

    /// 新建或就地更新一个服务档案（带 `id` 就更新）。`key` 非空时一并写入
    /// Keychain；`key` 传空字符串表示删除该档案的 Key。
    static func aiProfileUpsert(
        id raw: String?,
        name: String,
        endpoint: String,
        model: String,
        models: [String],
        headers: [String: String],
        key: String?
    ) -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        let store = app.aiPreference
        guard !endpoint.isEmpty else { return ["error": "endpoint required"] }

        let profileID: UUID
        if let raw, let id = UUID(uuidString: raw) {
            guard let index = store.profiles.firstIndex(where: { $0.id == id }) else {
                return ["error": "no such profile"]
            }
            if !name.isEmpty { store.profiles[index].name = name }
            store.profiles[index].endpoint = endpoint
            store.profiles[index].model = model
            if !models.isEmpty { store.profiles[index].modelList = models }
            if !headers.isEmpty { store.profiles[index].headers = headers }
            profileID = id
        } else {
            let created = store.addProfile(name: name, endpoint: endpoint, model: model)
            if let index = store.profiles.firstIndex(where: { $0.id == created.id }) {
                if !models.isEmpty { store.profiles[index].modelList = models }
                if !headers.isEmpty { store.profiles[index].headers = headers }
            }
            profileID = created.id
        }

        if let key {
            if key.isEmpty {
                store.deleteAPIKey(profileID: profileID)
            } else {
                store.saveAPIKey(key, profileID: profileID)
            }
        }
        return ["ok": true, "id": profileID.uuidString]
    }

    /// 从某个服务的 `/models` 拉取模型清单并并进该档案——设置页的"Fetch from API"
    /// 与输入栏菜单的"Refresh Model List"走的是同一个 `ModelListFetcher`。
    static func aiFetchModels(id raw: String?) async -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        let store = app.aiPreference
        let profile: AIProviderProfile?
        if let raw, let id = UUID(uuidString: raw) {
            profile = store.profiles.first { $0.id == id }
        } else {
            profile = store.activeProfile
        }
        guard let profile else { return ["error": "no such profile"] }
        let key = store.loadAPIKey(profileID: profile.id) ?? ""
        let models = (try? await ModelListFetcher.fetch(endpoint: profile.endpoint, apiKey: key)) ?? []
        guard !models.isEmpty else {
            return ["error": "no models returned", "endpoint": profile.endpoint]
        }
        if let index = store.profiles.firstIndex(where: { $0.id == profile.id }) {
            var seen = Set(store.profiles[index].modelList)
            for model in models where !seen.contains(model) {
                seen.insert(model)
                store.profiles[index].modelList.append(model)
            }
        }
        return [
            "ok": true,
            "profile": profile.name,
            "count": models.count,
            "models": models,
            "modelList": store.profiles.first { $0.id == profile.id }?.modelList ?? [],
        ]
    }

    /// 切当前模型（走 `preference.model` 的 setter——输入栏菜单点一下走的是
    /// 同一条路径），顺带把 providerKind 固定成 cloud，与菜单行为一致。
    static func aiSetModel(_ model: String) -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        guard !model.isEmpty else { return ["error": "model required"] }
        let store = app.aiPreference
        store.model = model
        store.providerKind = .cloud
        return ["ok": true, "model": store.model, "profile": store.activeProfile?.name ?? ""]
    }

    static func aiProfileActivate(id raw: String) -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        guard let id = UUID(uuidString: raw) else { return ["error": "bad id"] }
        let store = app.aiPreference
        guard store.profiles.contains(where: { $0.id == id }) else { return ["error": "no such profile"] }
        store.activateProfile(id: id)
        store.providerKind = .cloud
        return [
            "ok": true,
            "active": id.uuidString,
            "endpoint": store.endpoint,
            "model": store.model,
            "hasKey": store.hasAPIKey,
        ]
    }

    static func aiProfileDelete(id raw: String) -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        guard let id = UUID(uuidString: raw) else { return ["error": "bad id"] }
        let removed = app.aiPreference.deleteProfile(id: id)
        return removed ? ["ok": true] : ["error": "profile is built-in or missing"]
    }

    /// 模型单价表（成本折算用）。`models` 里给出**每个模型**的 in/out 单价
    /// （美元 / 每百万 token）；值传 0 或省略 = 未知 → 那个模型不显示金额。
    /// `remove` 里的模型直接删掉条目。
    static func aiPrices(models: [String: [String: Double]]?, remove: [String]?) -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        let store = app.aiPreference
        if let models {
            for (model, fields) in models where !model.isEmpty {
                store.modelPrices[model] = ModelPrice(inputPerMTok: fields["input"] ?? 0,
                                                      outputPerMTok: fields["output"] ?? 0)
            }
        }
        for model in remove ?? [] { store.modelPrices.removeValue(forKey: model) }
        return ["ok": true, "prices": aiPriceRows(store)]
    }

    /// 单价表的只读视图：带上"这个模型有没有历史用量的口径"给脚本对账用。
    static func aiPriceList() -> [String: Any] {
        guard let app = AppState.live else { return ["error": "app state not ready"] }
        let store = app.aiPreference
        return ["prices": aiPriceRows(store), "models": store.priceableModels]
    }

    private static func aiPriceRows(_ store: AgentPreferenceStore) -> [[String: Any]] {
        store.modelPrices.keys.sorted().map { model in
            let price = store.modelPrices[model] ?? ModelPrice()
            return ["model": model,
                    "input": price.inputPerMTok,
                    "output": price.outputPerMTok,
                    "known": price.isKnown]
        }
    }
}
