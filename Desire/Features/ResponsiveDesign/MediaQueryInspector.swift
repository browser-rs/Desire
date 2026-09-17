import SwiftUI

let mediaQueryExtractorJS = """
(function() {
    const rules = [];
    try {
        for (const sheet of document.styleSheets) {
            try {
                for (const rule of sheet.cssRules) {
                    if (rule.media && rule.media.mediaText) {
                        rules.push({
                            query: rule.media.mediaText,
                            active: window.matchMedia(rule.media.mediaText).matches
                        });
                    }
                }
            } catch(e) {}
        }
    } catch(e) {}
    return rules;
})();
"""

struct MediaQueryInspector: View {
    let queries: [MediaQueryItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Media Queries")
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

            Divider()

            if queries.isEmpty {
                Text("No media queries found")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(10)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(queries) { item in
                        HStack {
                            Circle()
                                .fill(item.isActive ? Color.green : Color.gray.opacity(0.4))
                                .frame(width: 6, height: 6)
                            Text(item.query)
                                .font(.system(size: 10))
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        Divider()
                    }
                }
            }
        }
        .background(.bar)
        .cornerRadius(6)
    }
}
