import SwiftUI

struct QuickDial: Identifiable {
    let id = UUID()
    let title: String
    let url: String
    let icon: String
}

let defaultDials = [
    QuickDial(title: "Google", url: "https://www.google.com", icon: "magnifyingglass"),
    QuickDial(title: "YouTube", url: "https://www.youtube.com", icon: "play.rectangle"),
    QuickDial(title: "GitHub", url: "https://github.com", icon: "chevron.left.forwardslash.chevron.right"),
    QuickDial(title: "Wikipedia", url: "https://www.wikipedia.org", icon: "book"),
    QuickDial(title: "Reddit", url: "https://www.reddit.com", icon: "bubble.left.and.bubble.right"),
    QuickDial(title: "Apple", url: "https://www.apple.com", icon: "apple.logo"),
    QuickDial(title: "Twitter/X", url: "https://x.com", icon: "bird"),
    QuickDial(title: "Baidu", url: "https://www.baidu.com", icon: "spider"),
]

struct NewTabPage: View {
    @Binding var urlString: String
    var onNavigate: (String) -> Void
    @State private var searchText = ""

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    var body: some View {
        VStack(spacing: 0) {
            TextField("搜索或输入网址", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .frame(maxWidth: 480)
                .padding(.horizontal)
                .padding(.top, 60)
                .onSubmit {
                    onNavigate(searchText)
                }

            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(defaultDials) { dial in
                        quickDialButton(dial)
                    }
                }
                .padding(.horizontal, 40)
                .padding(.top, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func quickDialButton(_ dial: QuickDial) -> some View {
        Button {
            urlString = dial.url
            onNavigate(dial.url)
        } label: {
            VStack(spacing: 8) {
                Image(systemName: dial.icon)
                    .font(.title)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 48, height: 48)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                Text(dial.title)
                    .font(.caption)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}
