import SwiftUI

struct UserScriptPanel: View {
    @ObservedObject var store: UserScriptStore
    var onAdd: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("用户脚本").font(.headline)
                Spacer()
                Button("", systemImage: "plus", action: onAdd)
                    .labelStyle(.iconOnly)
                Button("关闭", action: onClose)
            }
            .padding()

            if store.scripts.isEmpty {
                EmptyState(message: "暂无用户脚本")
            } else {
                List(store.scripts) { script in
                    HStack {
                        Toggle(isOn: Binding(
                            get: { script.isEnabled },
                            set: { enabled in
                                var s = script
                                s.isEnabled = enabled
                                store.update(s)
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(script.name).lineLimit(1).font(.body)
                                Text(script.urlPattern).lineLimit(1).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("", systemImage: "trash", action: { store.remove(script) })
                            .labelStyle(.iconOnly)
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(width: 420, height: 400)
    }
}
