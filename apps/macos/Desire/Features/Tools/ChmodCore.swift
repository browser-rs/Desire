import Foundation

/// Unix 权限（v0.8.33 开发批）：八进制 ↔ rwx 勾选 ↔ 符号式。
/// 纯 Foundation、进 tests/run.sh。
nonisolated enum ChmodCore {

    struct Permissions: Equatable, Sendable {
        var ownerRead = false
        var ownerWrite = false
        var ownerExecute = false
        var groupRead = false
        var groupWrite = false
        var groupExecute = false
        var otherRead = false
        var otherWrite = false
        var otherExecute = false
        var setuid = false
        var setgid = false
        var sticky = false

        var octalDigits: (special: Int, owner: Int, group: Int, other: Int) {
            let special = (setuid ? 4 : 0) | (setgid ? 2 : 0) | (sticky ? 1 : 0)
            let owner = (ownerRead ? 4 : 0) | (ownerWrite ? 2 : 0) | (ownerExecute ? 1 : 0)
            let group = (groupRead ? 4 : 0) | (groupWrite ? 2 : 0) | (groupExecute ? 1 : 0)
            let other = (otherRead ? 4 : 0) | (otherWrite ? 2 : 0) | (otherExecute ? 1 : 0)
            return (special, owner, group, other)
        }
    }

    /// `755` / `4755` / `0755` → 权限；非法返回 nil。
    static func parseOctal(_ text: String) -> Permissions? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard (3...4).contains(trimmed.count), trimmed.allSatisfy(\.isNumber) else { return nil }
        let digits = trimmed.compactMap { $0.wholeNumberValue }
        let special = digits.count == 4 ? digits[0] : 0
        let owner = digits[digits.count - 3]
        let group = digits[digits.count - 2]
        let other = digits[digits.count - 1]
        guard [special, owner, group, other].allSatisfy({ (0...7).contains($0) }) else {
            return nil
        }
        return Permissions(
            ownerRead: owner & 4 != 0, ownerWrite: owner & 2 != 0, ownerExecute: owner & 1 != 0,
            groupRead: group & 4 != 0, groupWrite: group & 2 != 0, groupExecute: group & 1 != 0,
            otherRead: other & 4 != 0, otherWrite: other & 2 != 0, otherExecute: other & 1 != 0,
            setuid: special & 4 != 0, setgid: special & 2 != 0, sticky: special & 1 != 0)
    }

    /// `rwxr-xr-x` / `rwsr-xr-x` / `rwxrwxrwt` → 权限；非法返回 nil。
    static func parseSymbolic(_ text: String) -> Permissions? {
        let characters = Array(text.trimmingCharacters(in: .whitespaces))
        guard characters.count == 9 else { return nil }
        func read(_ offset: Int) -> (Bool, Bool, Bool) {
            (characters[offset] == "r", characters[offset + 1] == "w",
             characters[offset + 2] == "x" || characters[offset + 2] == "s"
                || characters[offset + 2] == "t")
        }
        let owner = read(0)
        let group = read(3)
        let other = read(6)
        let ownerExecute = characters[2]
        let groupExecute = characters[5]
        let otherExecute = characters[8]
        guard ["x", "s", "S", "-"].contains(ownerExecute),
              ["x", "s", "S", "-"].contains(groupExecute),
              ["x", "t", "T", "-"].contains(otherExecute) else { return nil }
        return Permissions(
            ownerRead: owner.0, ownerWrite: owner.1, ownerExecute: owner.2,
            groupRead: group.0, groupWrite: group.1, groupExecute: group.2,
            otherRead: other.0, otherWrite: other.1, otherExecute: other.2,
            setuid: ownerExecute == "s" || ownerExecute == "S",
            setgid: groupExecute == "s" || groupExecute == "S",
            sticky: otherExecute == "t" || otherExecute == "T")
    }

    /// `755` / `4755`（非零特殊位才输出 4 位）。
    static func octalString(_ permissions: Permissions) -> String {
        let digits = permissions.octalDigits
        if digits.special != 0 {
            return "\(digits.special)\(digits.owner)\(digits.group)\(digits.other)"
        }
        return "\(digits.owner)\(digits.group)\(digits.other)"
    }

    /// `rwxr-xr-x` / `rwsr-xr-x` / `rwxrwxrwt`。
    static func symbolicString(_ permissions: Permissions) -> String {
        func triad(read: Bool, write: Bool, execute: Bool, special: Character?) -> String {
            var output = ""
            output.append(read ? "r" : "-")
            output.append(write ? "w" : "-")
            if let special {
                output.append(special)
            } else {
                output.append(execute ? "x" : "-")
            }
            return output
        }
        let ownerSpecial: Character? = permissions.setuid
            ? (permissions.ownerExecute ? "s" : "S") : nil
        let groupSpecial: Character? = permissions.setgid
            ? (permissions.groupExecute ? "s" : "S") : nil
        let otherSpecial: Character? = permissions.sticky
            ? (permissions.otherExecute ? "t" : "T") : nil
        return triad(read: permissions.ownerRead, write: permissions.ownerWrite,
                     execute: permissions.ownerExecute, special: ownerSpecial)
            + triad(read: permissions.groupRead, write: permissions.groupWrite,
                    execute: permissions.groupExecute, special: groupSpecial)
            + triad(read: permissions.otherRead, write: permissions.otherWrite,
                    execute: permissions.otherExecute, special: otherSpecial)
    }

    /// `u=rwx,g=rx,o=x` 形式。
    static func absoluteSymbolic(_ permissions: Permissions) -> String {
        func letters(_ read: Bool, _ write: Bool, _ execute: Bool) -> String {
            (read ? "r" : "") + (write ? "w" : "") + (execute ? "x" : "")
        }
        return "u=\(letters(permissions.ownerRead, permissions.ownerWrite, permissions.ownerExecute)),"
            + "g=\(letters(permissions.groupRead, permissions.groupWrite, permissions.groupExecute)),"
            + "o=\(letters(permissions.otherRead, permissions.otherWrite, permissions.otherExecute))"
    }
}
