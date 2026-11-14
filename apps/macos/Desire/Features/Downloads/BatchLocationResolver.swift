import Foundation

/// 批量下载落点解析（Foundation-only，进 tests/run.sh）。
///
/// 用户给的"存放位置"与配置的批根目录（`batch.baseDirectory`）之间做智能
/// 归并——用户路径可能恰好等于根目录、可能是根目录下的子目录、也可能是根
/// 目录之外的独立位置，三种形态各有明确落位（2026-11-14 用户定案：
/// "存储位置要智能判断"，不许"绝对路径一律当陌生根目录直落"）：
/// 1. 没给 → 默认链：根目录 + 子文件夹名（调用方通常给站点 host）；
/// 2. 裸名字（无路径分隔符）→ 根目录下的子文件夹；
/// 3. 绝对路径：
///    · 等于根目录 → 视同默认（host 子夹照垫——用户指的就是根目录本身，
///      与"没指定"同义，避免整批平铺在根目录）；
///    · 在根目录之下 → 超出部分就是子文件夹路径（**不再垫默认名**：用户
///      点了名的文件夹就是落点，双层嵌套是已知事故形态）；分卷规则照常
///      在其下生效；
///    · 在根目录之外 → 用户显式指定，原样直落（用户意图 > 根目录设置），
///      落点随批持久化的语义不变。
/// `folderName` 误传绝对路径 = 等价 directory（历史行为保留）。
enum BatchLocationResolver {

    /// 归并结果：`saveRoot == nil` 表示用批根目录；`folderName` 是其下的
    /// 子文件夹路径（可多级，组件已消毒；空串 = 直落根目录本身）。
    struct Resolution: Equatable {
        var saveRoot: String?
        var folderName: String
    }

    static func resolve(directory: String?, folderName: String?,
                        baseDirectory: String?,
                        defaultFolderName: String) -> Resolution {
        // 规范化：去空白、展开 ~、去尾分隔符；"/" / "." / ".." 视为没给。
        func normalize(_ raw: String?) -> String? {
            guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !s.isEmpty, s != "/", s != ".", s != ".." else { return nil }
            s = NSString(string: s).expandingTildeInPath
            while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
            return s.isEmpty || s == "/" || s == "." || s == ".." ? nil : s
        }
        var dir = normalize(directory)
        let base = normalize(baseDirectory)

        var folderInput = folderName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if folderInput == "." || folderInput == ".." { folderInput = "" }

        // folderName 误传绝对路径 = 整段就是目标目录（优先于 directory）。
        if folderInput.hasPrefix("/"), folderInput != "/" {
            dir = normalize(folderInput)
            folderInput = ""
        }

        // 多级子路径按组件消毒后重拼（sanitizedFileName 会把 "/" 打成横杠）。
        func sanitizeFolder(_ raw: String) -> String {
            raw.split(separator: "/")
                .map { BatchMediaPlan.sanitizedFileName(from: String($0), fallback: "") }
                .filter { !$0.isEmpty }
                .joined(separator: "/")
        }

        // 1) 没给 directory → 默认链（folderName 已由调用方垫好，通常为 host）。
        guard let dir else {
            let folder = sanitizeFolder(folderInput.isEmpty ? defaultFolderName : folderInput)
            return Resolution(saveRoot: nil, folderName: folder.isEmpty ? sanitizeFolder(defaultFolderName) : folder)
        }

        // 2) 裸名字（展开后无 "/"）→ 根目录下的子文件夹名。
        guard dir.contains("/") else {
            let folder = folderInput.isEmpty ? dir : dir + "/" + folderInput
            return Resolution(saveRoot: nil, folderName: sanitizeFolder(folder))
        }

        // 3) 绝对路径：与根目录比对归并（macOS 默认文件系统大小写不敏感）。
        let lowerDir = dir.lowercased()
        let lowerBase = base?.lowercased()
        if let lowerBase {
            if lowerDir == lowerBase {
                // 等于根目录 → 视同默认，host 子夹照垫。
                let folder = sanitizeFolder(folderInput.isEmpty ? defaultFolderName : folderInput)
                return Resolution(saveRoot: nil, folderName: folder.isEmpty ? sanitizeFolder(defaultFolderName) : folder)
            }
            if lowerDir.hasPrefix(lowerBase + "/") {
                // 根目录之下 → 超出部分即子文件夹路径，不再垫默认名。
                let sub = String(dir.dropFirst(lowerBase.count + 1))
                let combined = folderInput.isEmpty ? sub : sub + "/" + folderInput
                return Resolution(saveRoot: nil, folderName: sanitizeFolder(combined))
            }
        }
        // 4) 根目录之外（或未配置根目录）→ 用户显式指定，原样直落。
        return Resolution(saveRoot: dir, folderName: sanitizeFolder(folderInput))
    }
}
