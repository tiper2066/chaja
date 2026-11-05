import Foundation
import Observation

nonisolated struct SavedSearch: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var criteria: SearchCriteria
}

nonisolated struct RecentSearch: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var criteria: SearchCriteria
    var date: Date
}

/// 저장된 검색과 최근 검색을 `~/Library/Application Support/Chaja/searches.json`에 보관한다.
@Observable
final class SearchLibrary {
    static let recentLimit = 10

    private(set) var saved: [SavedSearch] = []
    private(set) var recent: [RecentSearch] = []

    private let fileURL: URL

    private struct Storage: Codable {
        var saved: [SavedSearch]
        var recent: [RecentSearch]
    }

    init(fileURL: URL = SearchLibrary.defaultFileURL) {
        self.fileURL = fileURL
        load()
    }

    static var defaultFileURL: URL {
        URL.applicationSupportDirectory.appending(path: "Chaja/searches.json")
    }

    func save(_ criteria: SearchCriteria, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        saved.append(SavedSearch(name: trimmed.isEmpty ? criteria.summary : trimmed, criteria: criteria))
        persist()
    }

    func rename(_ search: SavedSearch, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = saved.firstIndex(where: { $0.id == search.id }) else { return }
        saved[index].name = trimmed
        persist()
    }

    func delete(_ search: SavedSearch) {
        saved.removeAll { $0.id == search.id }
        persist()
    }

    func move(from source: IndexSet, to destination: Int) {
        saved.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    /// 같은 조건은 맨 위로 올리고, 앞 검색어를 이어서 입력한 경우(‘견’ → ‘견적’)는 앞 기록을 대체한다.
    func recordRecent(_ criteria: SearchCriteria) {
        guard criteria.hasConditions else { return }
        recent.removeAll { $0.criteria.isSameSearch(as: criteria) || Self.isRefinement(of: $0.criteria, by: criteria) }
        recent.insert(RecentSearch(criteria: criteria, date: .now), at: 0)
        if recent.count > Self.recentLimit { recent.removeLast(recent.count - Self.recentLimit) }
        persist()
    }

    func clearRecent() {
        recent = []
        persist()
    }

    private static func isRefinement(of old: SearchCriteria, by new: SearchCriteria) -> Bool {
        var oldWithoutText = old
        var newWithoutText = new
        oldWithoutText.text = ""
        newWithoutText.text = ""
        guard oldWithoutText.isSameSearch(as: newWithoutText), !old.trimmedText.isEmpty else { return false }
        return new.trimmedText.hasPrefix(old.trimmedText)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let storage = try? JSONDecoder().decode(Storage.self, from: data) else { return }
        saved = storage.saved
        recent = storage.recent
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Storage(saved: saved, recent: recent))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Chaja: 검색 기록 저장 실패 — \(error.localizedDescription)")
        }
    }
}
