import Foundation

/// 결과에서 뺄 폴더. "node_modules"처럼 이름만 쓰면 어디에 있든 제외하고,
/// "/"나 "~"로 시작하면 그 경로 아래만 제외한다.
nonisolated struct ExclusionRules: Equatable, Sendable {
    static let defaultEntries = ["node_modules", ".git", "DerivedData", "~/Library/Caches"]
    static let none = ExclusionRules(entries: [])

    let entries: [String]
    private let names: Set<String>
    private let prefixes: [String]

    init(entries: [String]) {
        let cleaned = entries
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        self.entries = cleaned
        var names = Set<String>()
        var prefixes: [String] = []
        for entry in cleaned {
            if entry.hasPrefix("/") || entry.hasPrefix("~") {
                let expanded = (entry as NSString).expandingTildeInPath
                prefixes.append(expanded.hasSuffix("/") ? expanded : expanded + "/")
            } else {
                names.insert(entry)
            }
        }
        self.names = names
        self.prefixes = prefixes
    }

    var isEmpty: Bool { entries.isEmpty }

    func excludes(path: String) -> Bool {
        if !prefixes.isEmpty {
            let directoryPath = path + "/"
            if prefixes.contains(where: { directoryPath.hasPrefix($0) }) { return true }
        }
        guard !names.isEmpty else { return false }
        return path.split(separator: "/").contains { names.contains(String($0)) }
    }
}
