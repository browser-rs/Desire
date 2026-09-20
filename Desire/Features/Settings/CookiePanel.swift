import SwiftUI

struct CookiePanel: View {
    @StateObject private var store = CookieStore()
    @State private var selectedDomain: String?
    @State private var showClearConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Cookies").font(.headline)
                Spacer()
                if !store.cookies.isEmpty {
                    Button("Clear All") { showClearConfirm = true }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                }
                Button("Refresh") { store.refresh() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .disabled(store.isLoading)
            }
            .padding(12)

            if !store.cookies.isEmpty {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search cookies…", text: $store.searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                    if !store.searchQuery.isEmpty {
                        Button { store.searchQuery = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }

            if store.isLoading {
                Spacer()
                ProgressView()
                Spacer()
            } else if store.cookies.isEmpty {
                EmptyState(message: String(localized: "No Cookies"))
            } else {
                List(selection: $selectedDomain) {
                    ForEach(store.domains, id: \.self) { domain in
                        Section(domain) {
                            ForEach(store.cookies(for: domain)) { cookie in
                                CookieRow(cookie: cookie, onDelete: { store.delete(cookie) })
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .font(.system(size: 11))
            }
        }
        .frame(width: 480, height: 360)
        .onAppear { store.refresh() }
        .alert("Clear All Cookies", isPresented: $showClearConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) { store.clearAll() }
        } message: {
            Text("This will remove all cookies. Some websites may log you out.")
        }
    }
}

private struct CookieRow: View {
    let cookie: CookieEntry
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(cookie.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Spacer()
                if cookie.isSecure {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.green)
                }
                if cookie.isHttpOnly {
                    Text("HttpOnly")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(2)
                }
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Delete Cookie")
            }
            Text(cookie.value)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let expiry = cookie.expiryDate {
                Text("Expires: \(expiry.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}
