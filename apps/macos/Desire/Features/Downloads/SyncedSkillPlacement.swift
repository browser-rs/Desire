import Foundation

/// **同步技能落在哪里**（v0.8.77，Foundation-only 进 tests/run.sh）。
///
/// 站点下载规则的说明性技能按"主机名-download"命名。这个名字可能已经被一份**别的技能**
/// 占着——用户手写的，或智能体在某次任务里自己存的（实测：内置批量下载被弃用的那个站点，
/// 事发当晚存下的"绝不要用"技能恰好就叫这个名）。同步是机器写的，**绝不覆盖不是自己
/// 写的文件**：名字被占就顺延（`-site`、`-site-2`…），落点在多次同步之间保持稳定。
nonisolated enum SyncedSkillPlacement {

    /// 技能正文里的标记：带它的才是本机制写出来的。
    static let marker = "<!-- synced from DPP adapter download rules -->"

    /// 同步技能的名字 → 文件名。
    static func fileName(for skillName: String) -> String {
        FilePathing.sanitizeFileName(skillName) + ".md"
    }

    /// 这份正文是不是本机制写的（不存在 = 不是）。
    static func isSynced(_ text: String?) -> Bool {
        text?.contains(marker) == true
    }

    /// `skillName` 的落点（名字 + 路径）。
    ///
    /// - `registered`：以前登记过的落点。位置上仍是本机制写的文件 → 沿用（多次同步之间
    ///   不换地方）；位置空了或已经换成别人的技能 → 重新找。
    /// - 重新找：候选名依次为原名、`-site`、`-site-2`…，取第一个**位置空着、或位置上的
    ///   文件是本机制写的**候选。
    /// - `textAt`：读某路径上的现有正文（不存在 = nil）。
    static func destination(in directory: URL, skillName: String, registered: String? = nil,
                            textAt: (URL) -> String?) -> (name: String, path: URL) {
        if let registered {
            let path = directory.appendingPathComponent(fileName(for: registered))
            if isSynced(textAt(path)) { return (registered, path) }
        }
        for index in 0..<100 {
            let name = index == 0 ? skillName : "\(skillName)-site\(index == 1 ? "" : "-\(index)")"
            let path = directory.appendingPathComponent(fileName(for: name))
            if isSynced(textAt(path)) || !FileManager.default.fileExists(atPath: path.path) {
                return (name, path)
            }
        }
        // 一百个候选名都被占（不可能出现的情况）：给一个确定的名字，交给调用方的写盘去失败。
        return ("\(skillName)-site-overflow",
                directory.appendingPathComponent(fileName(for: "\(skillName)-site-overflow")))
    }
}
