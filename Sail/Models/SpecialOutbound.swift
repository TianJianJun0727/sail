import Foundation

enum SpecialOutbound {
    nonisolated static let direct = "direct"
    nonisolated static let blocked: Set<String> = ["reject", "reject-drop", "pass", "block", "dns"]
    nonisolated static let all: Set<String> = blocked.union([direct])

    nonisolated static func isSpecial(_ name: String) -> Bool {
        all.contains(name.lowercased())
    }

    nonisolated static func isBlocked(_ name: String) -> Bool {
        blocked.contains(name.lowercased())
    }
}
