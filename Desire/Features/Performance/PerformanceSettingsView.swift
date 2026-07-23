import SwiftUI

struct PerformanceSettingsView: View {
    @ObservedObject var performanceManager: PerformanceStore
    @AppStorage("enableTabSuspension") private var enableTabSuspension = true
    @AppStorage("suspendAfterMinutes") private var suspendAfterMinutes = 30
    @AppStorage("enableCacheCleanup") private var enableCacheCleanup = true

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Memory Status
            GroupBox(label: Label("Memory Status", systemImage: "memorychip")) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Current Memory Usage:")
                            .font(.system(size: 13))
                        Spacer()
                        Text("\(performanceManager.memoryUsage) MB")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(performanceManager.isUnderPressure ? .red : .primary)
                    }

                    if performanceManager.isUnderPressure {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("System under memory pressure")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button("Clear All Caches") {
                        performanceManager.clearAllCaches()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.vertical, 4)
            }

            // Tab Suspension
            GroupBox(label: Label("Tab Suspension", systemImage: "moon.zzz")) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Enable Tab Suspension", isOn: $enableTabSuspension)

                    if enableTabSuspension {
                        HStack {
                            Text("Suspend after:")
                            Spacer()
                            Picker("", selection: $suspendAfterMinutes) {
                                Text("5 minutes").tag(5)
                                Text("10 minutes").tag(10)
                                Text("30 minutes").tag(30)
                                Text("1 hour").tag(60)
                            }
                            .frame(width: 120)
                        }

                        Text("Suspended tabs free memory but need to reload when activated.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            // Cache Settings
            GroupBox(label: Label("Cache Management", systemImage: "internaldrive")) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Automatic Cache Cleanup", isOn: $enableCacheCleanup)

                    Text("Automatically clears browser cache when memory usage is high.")
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
    let manager = PerformanceStore()
    return PerformanceSettingsView(performanceManager: manager)
        .frame(width: 400)
}