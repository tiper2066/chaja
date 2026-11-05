import Foundation
import Testing
@testable import Chaja

struct ExclusionRulesTests {
    @Test func namesMatchAnyPathComponent() {
        let rules = ExclusionRules(entries: ["node_modules", ".git"])
        #expect(rules.excludes(path: "/Users/me/app/node_modules/react/index.js"))
        #expect(rules.excludes(path: "/Users/me/app/node_modules"))
        #expect(rules.excludes(path: "/Users/me/app/.git/HEAD"))
        #expect(!rules.excludes(path: "/Users/me/app/node_modules_backup/a.js"))
        #expect(!rules.excludes(path: "/Users/me/app/src/index.js"))
    }

    @Test func pathsMatchOnlyThatFolder() {
        let rules = ExclusionRules(entries: ["~/Library/Caches", "/opt/tmp/"])
        let home = NSHomeDirectory()
        #expect(rules.excludes(path: "\(home)/Library/Caches/com.app/data"))
        #expect(rules.excludes(path: "\(home)/Library/Caches"))
        #expect(!rules.excludes(path: "\(home)/Library/CachesOld/a"))
        #expect(!rules.excludes(path: "/Users/other/Library/Caches/a"))
        #expect(rules.excludes(path: "/opt/tmp/a"))
    }

    @Test func blankEntriesAreIgnored() {
        #expect(ExclusionRules(entries: [" ", ""]).isEmpty)
    }
}

struct SearchCriteriaCodingTests {
    @Test func decodesOldFormatWithMissingKeys() throws {
        let json = #"{"text":"정산","kinds":["document"],"scope":{"downloads":{}}}"#
        let criteria = try JSONDecoder().decode(SearchCriteria.self, from: Data(json.utf8))
        #expect(criteria.text == "정산")
        #expect(criteria.kinds == [.document])
        #expect(criteria.scope == .downloads)
        #expect(criteria.whereFrom == "")
        #expect(criteria.tags.isEmpty)
        #expect(criteria.applyExclusions)
    }

    @Test func roundTripsAllFields() throws {
        var criteria = SearchCriteria()
        criteria.text = "견적"
        criteria.textTarget = .nameAndContent
        criteria.extensionGroupIDs = [".pdf"]
        criteria.customExtensions = ["hwp"]
        criteria.minSizeMB = 1.5
        criteria.datePreset = .custom
        criteria.whereFrom = "kakao"
        criteria.tags = ["업무"]
        criteria.applyExclusions = false
        criteria.scope = .folder(URL(fileURLWithPath: "/Users/me/Projects"))
        let decoded = try JSONDecoder().decode(SearchCriteria.self, from: JSONEncoder().encode(criteria))
        #expect(decoded == criteria)
    }

    @Test func sameSearchIgnoresUnusedCustomDates() {
        var a = SearchCriteria()
        var b = SearchCriteria()
        a.text = "x"
        b.text = "x"
        b.customEndDate = .distantFuture
        #expect(a.isSameSearch(as: b))
        a.datePreset = .custom
        b.datePreset = .custom
        #expect(!a.isSameSearch(as: b))
    }

    @Test func summaryDescribesConditions() {
        var criteria = SearchCriteria()
        #expect(criteria.summary == "조건 없음")
        criteria.text = "정산"
        criteria.kinds = [.document]
        criteria.tags = ["업무"]
        criteria.scope = .downloads
        #expect(criteria.summary == "‘정산’ · 문서 · #업무 · 다운로드")
    }
}

struct SearchLibraryTests {
    private func makeLibrary() -> (SearchLibrary, URL) {
        let url = FileManager.default.temporaryDirectory.appending(path: "ChajaLibrary-\(UUID().uuidString)/searches.json")
        return (SearchLibrary(fileURL: url), url)
    }

    private func criteria(_ text: String) -> SearchCriteria {
        var criteria = SearchCriteria()
        criteria.text = text
        return criteria
    }

    @Test func savedSearchesPersist() throws {
        let (library, url) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        library.save(criteria("정산"), name: "  연말정산  ")
        library.save(criteria("견적"), name: "")
        #expect(library.saved.map(\.name) == ["연말정산", "‘견적’"])

        library.rename(library.saved[1], to: "견적서")
        library.delete(library.saved[0])

        let reloaded = SearchLibrary(fileURL: url)
        #expect(reloaded.saved.map(\.name) == ["견적서"])
        #expect(reloaded.saved[0].criteria.text == "견적")
    }

    @Test func recentSearchesDedupeAndKeepTen() {
        let (library, url) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        for index in 0..<12 { library.recordRecent(criteria("항목\(index)")) }
        #expect(library.recent.count == SearchLibrary.recentLimit)
        #expect(library.recent.first?.criteria.text == "항목11")

        library.recordRecent(criteria("항목5"))
        #expect(library.recent.count == SearchLibrary.recentLimit)
        #expect(library.recent.first?.criteria.text == "항목5")
        #expect(library.recent.filter { $0.criteria.text == "항목5" }.count == 1)
    }

    @Test func refinedTextReplacesPreviousRecent() {
        let (library, url) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        library.recordRecent(criteria("견"))
        library.recordRecent(criteria("견적"))
        library.recordRecent(SearchCriteria())
        #expect(library.recent.map(\.criteria.text) == ["견적"])
    }
}
