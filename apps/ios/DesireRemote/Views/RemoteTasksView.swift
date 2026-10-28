import SwiftUI

/// 定时任务面（v0.8.11）：手机新建/启停/删除/查看 Mac 上的 Agent 定时任务。
/// 数据走 Remote 通道（tasks 帧），Mac 侧 AgentScheduler 是唯一真相。
struct RemoteTasksView: View {
    @EnvironmentObject var client: RemoteClient
    @State private var showCreate = false
    /// 任务编辑（v0.8.19）：复用创建表单语义，Mac 端按名定位。
    @State private var editingTask: RemoteTask?
    @State private var newName = ""
    @State private var newPrompt = ""
    /// 0 = 每 N 分钟模式；1 = 每天定时模式。
    @State private var scheduleMode = 0
    @State private var intervalMinutes = 30
    @State private var dailyHour = 9
    @State private var dailyMinute = 0

    var body: some View {
        List {
            if let policy = client.notificationPolicy {
                Section("通知（Mac）") {
                    HStack {
                        Text("免打扰")
                        Spacer()
                        Text(policy.quietEnabled ? "\(policy.quietStart) – \(policy.quietEnd)" : "关闭")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("每日预算")
                        Spacer()
                        Text(policy.dailyLimit == 0 ? "不限" : "\(policy.dailyLimit) 条")
                            .foregroundStyle(.secondary)
                    }
                    Toggle(isOn: Binding(
                        get: { policy.nightOwl },
                        set: { client.setNightOwl($0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("夜间批处理档")
                            Text("免打扰时段预算放宽，夜间产物照常通知")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if policy.heldCount > 0 {
                        Text("\(policy.heldCount) 条通知被扣下合并")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            if client.tasks.isEmpty {
                Text("Mac 上还没有定时任务")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            }
            ForEach(client.tasks) { task in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(task.name)
                            .font(.subheadline.weight(.medium))
                        if task.builtin {
                            Text("内置")
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { task.enabled },
                            set: { _ in client.toggleTask(id: task.id) }))
                            .labelsHidden()
                            .disabled(task.builtin)
                    }
                    Text(task.recurrence)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let last = task.lastResult, !last.isEmpty {
                        Text(last)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                }
                .swipeActions(edge: .leading) {
                    Button {
                        editingTask = task
                    } label: {
                        Label("编辑", systemImage: "pencil")
                    }
                    .tint(.blue)
                    .disabled(task.builtin)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        client.removeTask(id: task.id)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                    .disabled(task.builtin)
                }
            }
        }
        .navigationTitle("定时任务")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(item: $editingTask) { task in
            TaskEditSheet(task: task) { name, prompt, minutes, hour, minute in
                client.updateTask(name: name, prompt: prompt,
                                  minutes: minutes, hour: hour, minute: minute)
            }
        }
        .onAppear {
            client.requestTasks()
            client.requestNotificationPolicy()
        }
        .refreshable { client.requestTasks() }
        .alert("新建定时任务", isPresented: $showCreate) {
            TextField("名称", text: $newName)
            TextField("提示词（可空 = 内置 weeklyReport）", text: $newPrompt)
            Picker("节奏", selection: $scheduleMode) {
                Text("每 N 分钟").tag(0)
                Text("每天定时").tag(1)
            }
            if scheduleMode == 0 {
                TextField("分钟（≥5）", value: $intervalMinutes, format: .number.grouping(.never))
                    .keyboardType(.numberPad)
            } else {
                TextField("时", value: $dailyHour, format: .number.grouping(.never))
                    .keyboardType(.numberPad)
                TextField("分", value: $dailyMinute, format: .number.grouping(.never))
                    .keyboardType(.numberPad)
            }
            Button("创建") {
                let trimmedName = newName.trimmingCharacters(in: .whitespaces)
                guard !trimmedName.isEmpty else { return }
                client.createTask(
                    name: trimmedName,
                    prompt: newPrompt,
                    minutes: scheduleMode == 0 ? max(5, intervalMinutes) : nil,
                    hour: scheduleMode == 1 ? dailyHour : nil,
                    minute: scheduleMode == 1 ? dailyMinute : nil)
                newName = ""; newPrompt = ""
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("任务在 Mac 上运行，结果回传本会话")
        }
    }
}
