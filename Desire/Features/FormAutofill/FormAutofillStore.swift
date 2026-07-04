import Combine
import Foundation

@MainActor
class FormAutofillStore: ObservableObject {
    @Published var profile: FormAutofillProfile {
        didSet { save() }
    }

    private let key = "desire.formAutofillProfile"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let profile = try? JSONDecoder().decode(FormAutofillProfile.self, from: data) {
            self.profile = profile
        } else {
            self.profile = FormAutofillProfile(
                givenName: "", familyName: "", email: "", phone: "",
                organization: "", streetAddress: "", city: "", state: "", zipCode: "", country: ""
            )
        }
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
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: key)
        }
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
