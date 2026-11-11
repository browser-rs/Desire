import Foundation

/// 批量纯工具（v0.8.51 批 4）：Agent 侧入口。立刻返回 job id，
/// 执行在 `BatchToolStore` 的后台任务里（长任务约定，不阻塞回合）。
/// 参数解析与桥共用 `BatchToolCore.parseRequest`。
extension BrowserToolProvider {

    func runBatchTool(_ args: [String: Any]) -> String {
        switch BatchToolCore.parseRequest(args) {
        case .failure(let error):
            return Self.fail(error.message)
        case .success(let request):
            guard let job = BatchToolStore.shared.start(action: request.action,
                                                        files: request.files,
                                                        options: request.options) else {
                return Self.fail("another batch is already running — wait for it or cancel it first")
            }
            return "Batch \(request.action.title) started as job \(job.uuidString) over "
                + "\(request.files.count) file(s). Per-file results land in the Jobs panel; "
                + "poll backgroundTaskStatus."
        }
    }
}
