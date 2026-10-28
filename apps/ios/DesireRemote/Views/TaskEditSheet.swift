import SwiftUI

/// 定时任务编辑（v0.8.19）：预填既有值，确认后走 updateTask
/// （Mac 端按任务名定位，prompt / 节奏可改；builtin 已在行侧禁用）。
struct TaskEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let task: RemoteTask
    let onSave: (String, String, Int?, Int?, Int?) -> Void

    @State private var name = ""
    @State private var prompt = ""
    @State private var scheduleMode = 0
    @State private var intervalMinutes = 30
    @State private var dailyHour = 9
    @State private var dailyMinute = 0

    var body: some View {
        NavigationStack {
            Form {
                Section("任务") {
                    TextField("名称", text: $name)
                    TextField("提示词", text: $prompt, axis: .vertical)
                        .lineLimit(3...6)
                }
                Section("节奏") {
                    Picker("模式", selection: $scheduleMode) {
                        Text("每 N 分钟").tag(0)
                        Text("每天定时").tag(1)
                    }
                    if scheduleMode == 0 {
                        Stepper("每 \(intervalMinutes) 分钟", value: $intervalMinutes, in: 5...720, step: 5)
                    } else {
                        Stepper("时：\(dailyHour)", value: $dailyHour, in: 0...23)
                        Stepper("分：\(dailyMinute)", value: $dailyMinute, in: 0...55, step: 5)
                    }
                }
                Section {
                    Text("Mac 端按任务名定位；提示词留空保持不变。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("编辑任务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let trimmedName = name.trimmingCharacters(in: .whitespaces)
                        guard !trimmedName.isEmpty else { return }
                        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespaces)
                        onSave(trimmedName, trimmedPrompt,
                               scheduleMode == 0 ? intervalMinutes : nil,
                               scheduleMode == 1 ? dailyHour : nil,
                               scheduleMode == 1 ? dailyMinute : nil)
                        dismiss()
                    }
                }
            }
            .onAppear {
                name = task.name
                prompt = task.prompt
                // 既有节奏解析（recurrenceText 三语经 String(localized)——
                // 中文"every N min"槽位化文案；按数字兜底解析）。
                if let m = task.recurrence.firstMatch(of: /(\d+)\s*min/) {
                    scheduleMode = 0
                    intervalMinutes = Int(m.1) ?? 30
                } else if let m = task.recurrence.firstMatch(of: /(\d{1,2}):(\d{2})/) {
                    scheduleMode = 1
                    dailyHour = Int(m.1) ?? 9
                    dailyMinute = Int(m.2) ?? 0
                }
            }
        }
    }
}
