import Security
import SwiftUI

struct SecurityInfoView: View {
    let trust: SecTrust?
    let host: String
    /// https 页面上的 http 子资源计数（0 = 无混合内容）。
    var mixedContentTotal: Int = 0
    var mixedContentScripts: Int = 0

    private var certInfo: [(String, String)] {
        guard let trust else { return [] }
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else { return [] }
        var info: [(String, String)] = []

        if let summary = SecCertificateCopySubjectSummary(leaf) as String? {
            info.append((String(localized: "Domain"), summary))
        }

        // The second cert in the chain is the issuer (CA)
        if chain.count >= 2 {
            let issuer = chain[1]
            if let name = SecCertificateCopySubjectSummary(issuer) as String? {
                info.append((String(localized: "Issuer"), name))
            }
        }

        return info
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: trust != nil ? "lock.fill" : "lock.open")
                    .foregroundStyle(trust != nil ? .green : .orange)
                Text(trust != nil ? "Connection Secure" : "Connection Not Secure")
                    .font(.headline)
            }

            Divider()

            Label(host, systemImage: "globe")
                .font(.body)
                .foregroundStyle(.secondary)

            if trust != nil {
                ForEach(certInfo, id: \.0) { label, value in
                    HStack(alignment: .top, spacing: 4) {
                        Text(label + ":")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(width: 60, alignment: .trailing)
                        Text(value)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Text("This connection is encrypted with HTTPS")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)

                if mixedContentTotal > 0 {
                    Divider()
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Mixed Content")
                            .font(.system(size: 12, weight: .medium))
                    }
                    Text("\(mixedContentTotal) resource(s) on this page load over insecure HTTP\(mixedContentScripts > 0 ? ", including \(mixedContentScripts) active script/frame loads" : ""). The connection is encrypted, but the page's contents may be tampered with.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            } else {
                Text("This connection is not encrypted")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.top, 4)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}

#Preview {
    SecurityInfoView(trust: nil, host: "example.com")
        .frame(width: 320)
}

#Preview("Secure") {
    SecurityInfoView(trust: nil, host: "secure.example.com")
        .frame(width: 320)
}
