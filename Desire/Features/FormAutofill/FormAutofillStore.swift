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

    var fillScript: String {
        """
        (function() {
            var p = \(profile.toJSON());
            function fill(name, value) {
                var el = document.querySelector('[name="' + name + '"], [id="' + name + '"], [autocomplete="' + name + '"]');
                if (el && !el.value) el.value = value;
            }
            fill('given-name', p.gn);
            fill('family-name', p.fn);
            fill('email', p.em);
            fill('tel', p.ph);
            fill('organization', p.or);
            fill('street-address', p.sa);
            fill('address-level2', p.ci);
            fill('address-level1', p.st);
            fill('postal-code', p.zc);
            fill('country', p.co);
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
