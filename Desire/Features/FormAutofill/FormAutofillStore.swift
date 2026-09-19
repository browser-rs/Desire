import Combine
import Foundation

@MainActor
class FormAutofillStore: ObservableObject {
    @Published var profile: FormAutofillProfile {
        didSet { save() }
    }

    /// DiskStore key. Also reused as the legacy UserDefaults key for the
    /// one-time migration.
    private let key = "desire.formAutofillProfile"

    init() {
        let empty = FormAutofillProfile(
            givenName: "", familyName: "", email: "", phone: "",
            organization: "", streetAddress: "", city: "", state: "", zipCode: "", country: ""
        )
        if let decoded = DiskStore.load(FormAutofillProfile.self, key: key) {
            self.profile = decoded
            return
        }
        // One-time migration from the legacy UserDefaults blob.
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode(FormAutofillProfile.self, from: data) {
            self.profile = decoded
            DiskStore.save(decoded, key: key)
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        self.profile = empty
    }

    var isConfigured: Bool {
        !profile.givenName.isEmpty || !profile.familyName.isEmpty || !profile.email.isEmpty
    }

    /// 0.3.6：走 dom-tools.js 的模糊分类填充（autocomplete token +
    /// name/id/placeholder 关键词分类，只填空字段），替代原先的精确
    /// 属性名匹配（name="given-name" 之外基本全失手）。
    var fillScript: String {
        """
        (function() {
            var p = \(profile.toJSON());
            if (typeof __desireFillProfile === 'function') {
                __desireFillProfile(p);
            }
        })();
        """
    }

    private func save() {
        DiskStore.save(profile, key: key)
    }
}

private extension FormAutofillProfile {
    func toJSON() -> String {
        let gn = givenName.replacingOccurrences(of: "'", with: "\\'")
        let fn = familyName.replacingOccurrences(of: "'", with: "\\'")
        let em = email.replacingOccurrences(of: "'", with: "\\'")
        let ph = phone.replacingOccurrences(of: "'", with: "\\'")
        let or = organization.replacingOccurrences(of: "'", with: "\\'")
        let sa = streetAddress.replacingOccurrences(of: "'", with: "\\'")
        let ci = city.replacingOccurrences(of: "'", with: "\\'")
        let st = state.replacingOccurrences(of: "'", with: "\\'")
        let zc = zipCode.replacingOccurrences(of: "'", with: "\\'")
        let co = country.replacingOccurrences(of: "'", with: "\\'")
        return "{gn:'\(gn)',fn:'\(fn)',em:'\(em)',ph:'\(ph)',or:'\(or)',sa:'\(sa)',ci:'\(ci)',st:'\(st)',zc:'\(zc)',co:'\(co)'}"
    }
}
