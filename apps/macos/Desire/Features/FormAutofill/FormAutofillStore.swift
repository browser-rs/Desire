import Combine
import Foundation

@MainActor
class FormAutofillStore: ObservableObject {
    /// 当前编辑中的档案（设置页直接绑定它）。
    @Published var profile: FormAutofillProfile {
        didSet { saveWorking() }
    }

    /// 保存下来的其它档案（v0.8.80 多档案）：工作档案之外的可切换副本。
    /// 每条都有 id/label；「保存当前档案」按 id 覆盖或追加。
    @Published private(set) var savedProfiles: [FormAutofillProfile] = []

    /// DiskStore key. Also reused as the legacy UserDefaults key for the
    /// one-time migration.
    private let profileKey = "desire.formAutofillProfile"
    private let savedKey = "desire.formAutofillSavedProfiles"

    init() {
        if let decoded = DiskStore.load(FormAutofillProfile.self, key: profileKey) {
            self.profile = decoded
        } else if let data = AppPrefs.defaults.data(forKey: profileKey),
                  let decoded = try? JSONDecoder().decode(FormAutofillProfile.self, from: data) {
            // One-time migration from the legacy UserDefaults blob.
            self.profile = decoded
            DiskStore.save(decoded, key: profileKey)
            AppPrefs.defaults.removeObject(forKey: profileKey)
        } else {
            self.profile = FormAutofillProfile()
        }
        self.savedProfiles = DiskStore.load([FormAutofillProfile].self, key: savedKey) ?? []
    }

    var isConfigured: Bool {
        !profile.givenName.isEmpty || !profile.familyName.isEmpty || !profile.email.isEmpty
    }

    /// 填充菜单里的候选：工作档案在前，保存的档案按 id 去重。
    var fillableProfiles: [FormAutofillProfile] {
        var list = [profile]
        list += savedProfiles.filter { $0.id != profile.id }
        return list.filter { candidate in
            !candidate.fullName.isEmpty || !candidate.email.isEmpty || !candidate.streetAddress.isEmpty
        }
    }

    /// 开一份新档案（v0.8.80）：给新 id，编辑区清空——保存时才进库。
    func newProfile() {
        profile = FormAutofillProfile()
    }

    /// 把当前编辑的档案存进库（同 id 覆盖；新 id 追加）。
    func saveCurrentToLibrary() {
        if let index = savedProfiles.firstIndex(where: { $0.id == profile.id }) {
            savedProfiles[index] = profile
        } else {
            savedProfiles.append(profile)
        }
        saveSaved()
    }

    /// 从库中载入一份档案到编辑区。
    func load(_ id: UUID) {
        guard let saved = savedProfiles.first(where: { $0.id == id }) else { return }
        profile = saved
    }

    func delete(_ id: UUID) {
        savedProfiles.removeAll { $0.id == id }
        saveSaved()
    }

    /// 0.3.6：走 dom-tools.js 的模糊分类填充（autocomplete token +
    /// name/id/placeholder 关键词分类，只填空字段），替代原先的精确
    /// 属性名匹配（name="given-name" 之外基本全失手）。
    /// v0.8.80：可指定档案（多档案菜单）；nil = 当前编辑的档案。
    func fillScript(for profileID: UUID? = nil) -> String {
        let target = profileID.flatMap { id in
            fillableProfiles.first(where: { $0.id == id })
        } ?? profile
        return """
        (function() {
            var p = \(target.toJSON());
            if (typeof __desireFillProfile === 'function') {
                __desireFillProfile(p);
            }
        })();
        """
    }

    private func saveWorking() {
        DiskStore.save(profile, key: profileKey)
    }

    private func saveSaved() {
        DiskStore.save(savedProfiles, key: savedKey)
    }
}

extension FormAutofillProfile {
    /// JS 字面量（旧手写只转义单引号——值含反斜杠或换行时整段注入即语法错；
    /// 地址字段带换行很常见）。
    func toJSON() -> String {
        "{gn:\(JSString.literal(givenName)),fn:\(JSString.literal(familyName)),"
        + "em:\(JSString.literal(email)),ph:\(JSString.literal(phone)),"
        + "or:\(JSString.literal(organization)),sa:\(JSString.literal(streetAddress)),"
        + "ci:\(JSString.literal(city)),st:\(JSString.literal(state)),"
        + "zc:\(JSString.literal(zipCode)),co:\(JSString.literal(country))}"
    }
}
