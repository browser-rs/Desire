import Foundation

/// The user's decision on a tool approval prompt. Returned by the UI.
/// Extracted from `AISessionStore.swift` (one-file-one-type rule).
enum ApprovalDecision {
    case allowOnce
    case alwaysAllow
    case deny
}

/// Internal outcome the agent loop acts on. Distinct from
/// `ApprovalDecision` because whitelisted / readonly tools resolve to
/// `.allowedOnce` without ever prompting the user.
enum ApprovalOutcome {
    case allowedOnce
    case allowedAlways
    case denied
}
