import SwiftUI

struct NetworkMonitorPanel: View {
    @ObservedObject var store: DevToolsStore
    @State private var searchText = ""
    @State private var selectedType: NetworkRequest.ResourceType? = nil
    @State private var selectedRequest: NetworkRequest?

    var filteredRequests: [NetworkRequest] {
        var requests = store.networkRequests
        if let type = selectedType {
            requests = requests.filter { $0.resourceType == type }
        }
        if !searchText.isEmpty {
            requests = requests.filter { $0.url.localizedCaseInsensitiveContains(searchText) }
        }
        return requests.reversed()
    }

    var body: some View {
        VStack(spacing: 0) {
            networkToolbar
            Divider()
            HSplitView {
                requestList
                requestDetail
            }
        }
    }

    private var networkToolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "network")
                .foregroundStyle(.secondary)

            TextField("Filter URLs", text: $searchText)
                .textFieldStyle(.roundedBorder)

            typeFilterButton

            Spacer()

            Text("\(store.networkRequests.count) requests")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if store.networkPendingCount > 0 {
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text("\(store.networkPendingCount) pending")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if store.networkFailedCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Text("\(store.networkFailedCount) failed")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.red)
                }
            }

            Button {
                store.clearNetworkRequests()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help("Clear Network Log")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var typeFilterButton: some View {
        Menu {
            Button("All Types") {
                selectedType = nil
            }
            ForEach(NetworkRequest.ResourceType.allCases, id: \.self) { type in
                Button(type.rawValue.capitalized) {
                    selectedType = type
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                if let type = selectedType {
                    Text(type.rawValue.capitalized)
                        .font(.system(size: 11))
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var requestList: some View {
        VStack(spacing: 0) {
            if filteredRequests.isEmpty {
                EmptyState(message: "No Network Requests")
                    .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(filteredRequests) { request in
                            NetworkRequestRow(request: request, isSelected: selectedRequest?.id == request.id)
                                .onTapGesture {
                                    selectedRequest = request
                                }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(minWidth: 300)
    }

    private var requestDetail: some View {
        VStack(spacing: 0) {
            if let request = selectedRequest {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        detailSection(title: "General", content: generalInfo(request))
                        if let headers = request.requestHeaders {
                            detailSection(title: "Request Headers", content: headersView(headers))
                        }
                        if let headers = request.responseHeaders {
                            detailSection(title: "Response Headers", content: headersView(headers))
                        }
                        if let body = request.requestBody {
                            detailSection(title: "Request Body", content: bodyView(body))
                        }
                        if let body = request.responseBody {
                            detailSection(title: "Response Body", content: bodyView(body))
                        }
                    }
                    .padding(12)
                }
            } else {
                EmptyState(message: "Select a Request")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 250)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func detailSection(title: String, content: some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            content
        }
    }

    private func generalInfo(_ request: NetworkRequest) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            detailRow("URL", request.url)
            detailRow("Method", request.method)
            if let status = request.statusCode {
                detailRow("Status", "\(status) \(request.statusText ?? "")")
            }
            if let mime = request.mimeType {
                detailRow("Type", mime)
            }
            if let duration = request.duration {
                detailRow("Duration", String(format: "%.2f ms", duration * 1000))
            }
            if request.failed {
                detailRow("Error", request.errorMessage ?? "Unknown error")
            }
        }
    }

    private func headersView(_ headers: [String: String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(headers.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                HStack(alignment: .top) {
                    Text(key)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func bodyView(_ body: String) -> some View {
        Text(body)
            .font(.system(size: 11, design: .monospaced))
            .textSelection(.enabled)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12))
                .textSelection(.enabled)
        }
    }
}

private struct NetworkRequestRow: View {
    let request: NetworkRequest
    let isSelected: Bool

    private var typeIcon: String {
        switch request.resourceType {
        case .document: return "doc.text"
        case .script: return "chevron.left.forwardslash.chevron.right"
        case .stylesheet: return "paintbrush"
        case .image: return "photo"
        case .font: return "textformat"
        case .media: return "play.circle"
        case .xhr: return "arrow.triangle.branch"
        case .fetch: return "arrow.triangle.branch"
        case .websocket: return "antenna.radiowaves.left.and.right"
        case .other: return "questionmark.circle"
        }
    }

    private var statusColor: Color {
        if request.failed { return .red }
        guard let status = request.statusCode else { return .secondary }
        if status < 200 { return .secondary }
        if status < 300 { return .green }
        if status < 400 { return .blue }
        return .red
    }

    private var durationString: String {
        guard let duration = request.duration else {
            return request.failed ? "Failed" : "Pending"
        }
        if duration < 0.001 {
            return "< 1 ms"
        }
        return String(format: "%.2f ms", duration * 1000)
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: typeIcon)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(request.url)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 4) {
                    Text(request.method)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)

                    if let status = request.statusCode {
                        Text("\(status)")
                            .font(.system(size: 10))
                            .foregroundStyle(statusColor)
                    }

                    Text(durationString)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        )
    }
}

#Preview {
    let store = DevToolsStore()
    let id1 = store.startNetworkRequest(url: "https://example.com/api/data", method: "GET", resourceType: .xhr)
    store.completeNetworkRequest(id: id1, statusCode: 200, statusText: "OK", mimeType: "application/json", responseHeaders: ["Content-Type": "application/json"], responseBody: "{\"data\": \"value\"}")
    let id2 = store.startNetworkRequest(url: "https://example.com/style.css", method: "GET", resourceType: .stylesheet)
    store.completeNetworkRequest(id: id2, statusCode: 404, statusText: "Not Found", mimeType: nil, responseHeaders: nil, responseBody: nil)
    return NetworkMonitorPanel(store: store)
        .frame(width: 600, height: 400)
}