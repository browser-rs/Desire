import Security
import SwiftUI

struct SecurityInfoView: View {
    let trust: SecTrust?
    let host: String

    private var certInfo: [(String, String)] {
        guard let trust else { return [] }
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else { return [] }
        var info: [(String, String)] = []

        if let summary = SecCertificateCopySubjectSummary(leaf) as String? {
            info.append(("域名", summary))
        }

        // The second cert in the chain is the issuer (CA)
        if chain.count >= 2 {
            let issuer = chain[1]
            if let name = SecCertificateCopySubjectSummary(issuer) as String? {
                info.append(("颁发者", name))
            }
        }

        return info
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: trust != nil ? "lock.fill" : "lock.open")
                    .foregroundStyle(trust != nil ? .green : .orange)
                Text(trust != nil ? "连接安全" : "连接不安全")
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

                Text("此连接使用 HTTPS 加密")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            } else {
                Text("此连接未加密")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.top, 4)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}
