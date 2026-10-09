import Combine
import Foundation
import os

/// Agent 人设名册（多 Agent roster v1，2026-10-09，取自 Dots 多 dot / Grok Bot
/// 多 Agent 群像）：一组命名的人设（名字 + 语气）。每个窗口的 Agent 面板可以
/// 绑定其中一个人设——绑定的窗口在 `<persona>` 层用人设的名字与语气自称，
/// 未绑定/人设被删则回落全局默认（AgentPreferenceStore.agentName/agentPersona）。
/// 系统提示词身份层保持全局：人设只换"它是谁"，不换"它知道什么"。
///
/// 绑定关系按调度器注册 id（registryID）存 UserDefaults；窗口关闭后残留的
/// 绑定键无害（查不到人设即回落）。
@MainActor
final class AgentRosterStore: ObservableObject {
    static let shared = AgentRosterStore()

    @Published private(set) var personas: [AgentPersona] {
        didSet { DiskStore.save(personas, key: "agent-personas") }
    }

    init() {
        personas = DiskStore.load([AgentPersona].self, key: "agent-personas") ?? []
    }

    struct AgentPersona: Identifiable, Codable, Equatable {
        let id: UUID
        var name: String
        var tone: String
    }

    // MARK: - CRUD

    @discardableResult
    func add(name: String, tone: String) -> AgentPersona? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let persona = AgentPersona(
            id: UUID(),
            name: trimmed,
            tone: tone.trimmingCharacters(in: .whitespacesAndNewlines))
        personas.append(persona)
        return persona
    }

    func update(id: UUID, name: String, tone: String) {
        guard let idx = personas.firstIndex(where: { $0.id == id }),
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        personas[idx].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        personas[idx].tone = tone.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func remove(id: UUID) {
        personas.removeAll { $0.id == id }
    }

    func persona(id: UUID?) -> AgentPersona? {
        guard let id else { return nil }
        return personas.first { $0.id == id }
    }

    // MARK: - 每窗口绑定

    private static func bindKey(_ registryID: UUID) -> String {
        "agentPersonaBind.\(registryID.uuidString)"
    }

    func binding(for registryID: UUID) -> UUID? {
        UserDefaults.standard.string(forKey: Self.bindKey(registryID))
            .flatMap(UUID.init(uuidString:))
    }

    func bind(personaID: UUID?, to registryID: UUID) {
        if let personaID {
            UserDefaults.standard.set(personaID.uuidString, forKey: Self.bindKey(registryID))
        } else {
            UserDefaults.standard.removeObject(forKey: Self.bindKey(registryID))
        }
    }

    /// 窗口显示名（面板标题/桥）：绑定了人设显示人设名，否则 nil（回落"Agent"）。
    func displayName(for registryID: UUID?) -> String? {
        guard let registryID else { return nil }
        return persona(id: binding(for: registryID))?.name
    }
}
