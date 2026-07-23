import SwiftUI
import WebKit

struct PrivacySettingsStoreView: View {
    @ObservedObject var settings: PrivacySettingsStore
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Tracking Protection
            GroupBox(label: Label("Tracking Protection", systemImage: "shield.checkered")) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Block Social Media Trackers", isOn: $settings.blockSocialMediaTrackers)
                        .onChange(of: settings.blockSocialMediaTrackers) { _, _ in settings.save() }
                    
                    Toggle("Block Analytics Trackers", isOn: $settings.blockAnalyticsTrackers)
                        .onChange(of: settings.blockAnalyticsTrackers) { _, _ in settings.save() }
                    
                    Toggle("Block Browser Fingerprinting", isOn: $settings.blockFingerprinting)
                        .onChange(of: settings.blockFingerprinting) { _, _ in settings.save() }
                    
                    Toggle("Block Cryptocurrency Miners", isOn: $settings.blockCryptominers)
                        .onChange(of: settings.blockCryptominers) { _, _ in settings.save() }
                }
                .padding(.vertical, 4)
            }
            
            // Cookie Settings
            GroupBox(label: Label("Cookie Settings", systemImage: "cookie")) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Block Third-Party Cookies", isOn: $settings.blockThirdPartyCookies)
                        .onChange(of: settings.blockThirdPartyCookies) { _, _ in settings.save() }
                    
                    Picker("Cookie Accept Policy:", selection: $settings.cookieAcceptPolicy) {
                        ForEach(PrivacySettingsStore.CookieAcceptPolicy.allCases, id: \.self) { policy in
                            Text(policy.displayName).tag(policy)
                        }
                    }
                    .onChange(of: settings.cookieAcceptPolicy) { _, _ in settings.save() }
                    
                    Text("Controls which cookies are accepted from websites.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            
            // HTTPS Upgrade
            GroupBox(label: Label("Connection Security", systemImage: "lock.shield")) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Enforce HTTPS Connections", isOn: $settings.enforceHTTPS)
                        .onChange(of: settings.enforceHTTPS) { _, _ in settings.save() }
                    
                    Text("Automatically upgrade HTTP connections to secure HTTPS.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            
            // Privacy Mode
            GroupBox(label: Label("Default Browsing Mode", systemImage: "eye")) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Enable Private Mode by Default", isOn: $settings.defaultPrivacyModeEnabled)
                        .onChange(of: settings.defaultPrivacyModeEnabled) { _, _ in settings.save() }
                    
                    Text("Private mode does not save browsing history, cookies, or cache.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .padding()
    }
}

#Preview {
    let settings = PrivacySettingsStore()
    return PrivacySettingsStoreView(settings: settings)
        .frame(width: 400)
}