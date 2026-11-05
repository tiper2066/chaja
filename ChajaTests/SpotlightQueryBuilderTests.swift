import Foundation
import Testing
@testable import Chaja

struct SpotlightQueryBuilderTests {
    private let fixedNow = ISO8601DateFormatter().date(from: "2026-11-05T05:00:00Z")!
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func query(_ configure: (inout SearchCriteria) -> Void) -> String {
        var criteria = SearchCriteria()
        configure(&criteria)
        return SpotlightQueryBuilder.queryString(for: criteria, now: fixedNow, calendar: utcCalendar)
    }

    @Test func emptyCriteriaMatchesEverything() {
        #expect(query { _ in } == SpotlightQueryBuilder.matchEverything)
    }

    @Test func nameWordsAreCombinedWithAnd() {
        #expect(query { $0.text = "  정산  2024 " }
            == #"kMDItemFSName == "*정산*"cd && kMDItemFSName == "*2024*"cd"#)
    }

    @Test func caseSensitiveDropsCaseModifier() {
        #expect(query { $0.text = "Report"; $0.caseSensitive = true } == #"kMDItemFSName == "*Report*"d"#)
    }

    @Test func contentSearchUsesWordPrefixMatch() {
        #expect(query { $0.text = "정산"; $0.textTarget = .nameAndContent }
            == #"(kMDItemFSName == "*정산*"cd || kMDItemTextContent == "정산*"cdw)"#)
    }

    @Test func whereFromUsesSubstringMatch() {
        #expect(query { $0.whereFrom = " drive.google " } == #"kMDItemWhereFroms == "*drive.google*"cd"#)
    }

    @Test func tagsAreCombinedWithOr() {
        #expect(query { $0.tags = ["업무", "빨간색"] }
            == #"(kMDItemUserTags == "빨간색"cd || kMDItemUserTags == "업무"cd)"#)
        #expect(query { $0.tags = ["업무"]; $0.extensionGroupIDs = [".pdf"] }
            == #"kMDItemFSName == "*.pdf"c && kMDItemUserTags == "업무"cd"#)
    }

    @Test func specialCharactersAreEscaped() {
        #expect(SpotlightQueryBuilder.escape(#"a*b"c\d?"#) == #"a\*b\"c\\d\?"#)
    }

    @Test func extensionsAreCombinedWithOr() {
        #expect(query { $0.extensionGroupIDs = [".pdf"]; $0.customExtensions = ["sketch"] }
            == #"(kMDItemFSName == "*.pdf"c || kMDItemFSName == "*.sketch"c)"#)
    }

    @Test func duplicateExtensionsAreRemoved() {
        var criteria = SearchCriteria()
        criteria.extensionGroupIDs = [".pdf"]
        criteria.customExtensions = ["pdf", "key"]
        #expect(criteria.extensions == ["pdf", "key"])
    }

    @Test func movieKindExcludesTypeScriptFiles() {
        let string = query { $0.kinds = [.movie] }
        #expect(string.contains(#"kMDItemContentType != "public.mpeg-2-transport-stream""#))
    }

    @Test func sizeIsConvertedToBytes() {
        #expect(query { $0.minSizeMB = 10; $0.maxSizeMB = 100 }
            == "kMDItemFSSize >= 10485760 && kMDItemFSSize <= 104857600")
    }

    @Test func todayStartsAtMidnight() {
        #expect(query { $0.datePreset = .today }
            == "kMDItemFSContentChangeDate >= $time.iso(2026-11-05T00:00:00Z)")
    }

    @Test func customRangeIncludesWholeEndDay() {
        let string = query {
            $0.datePreset = .custom
            $0.dateField = .created
            $0.customStartDate = ISO8601DateFormatter().date(from: "2026-10-01T10:00:00Z")!
            $0.customEndDate = ISO8601DateFormatter().date(from: "2026-10-03T10:00:00Z")!
        }
        #expect(string == "kMDItemFSCreationDate >= $time.iso(2026-10-01T00:00:00Z) && kMDItemFSCreationDate < $time.iso(2026-10-04T00:00:00Z)")
    }

    @Test func allConditionsAreCombinedWithAnd() {
        let string = query {
            $0.text = "정산"
            $0.extensionGroupIDs = [".pdf"]
            $0.kinds = [.document]
            $0.maxSizeMB = 10
            $0.datePreset = .last30Days
        }
        #expect(string.components(separatedBy: " && ").count == 5)
    }

    @Test(arguments: FileKind.allCases)
    func everyKindProducesParsableQuery(kind: FileKind) {
        let string = query { $0.kinds = [kind]; $0.text = #"a"b*"#; $0.datePreset = .lastYear; $0.minSizeMB = 1 }
        #expect(NSPredicate(fromMetadataQueryString: string) != nil)
    }
}

struct FileMatcherTests {
    @Test func hangulNameMatchesRegardlessOfNormalization() {
        let composed = "연말정산.pdf".precomposedStringWithCanonicalMapping
        let decomposed = "연말정산.pdf".decomposedStringWithCanonicalMapping
        // Swift String의 ==는 정규화 차이를 무시하므로 스칼라 개수로 서로 다른 형태임을 확인한다.
        #expect(composed.unicodeScalars.count != decomposed.unicodeScalars.count)

        var criteria = SearchCriteria()
        criteria.text = "정산".decomposedStringWithCanonicalMapping
        let matcher = FileMatcher(criteria: criteria)
        #expect(matcher.matchesName(composed))
        #expect(matcher.matchesName(decomposed))
    }

    @Test func caseSensitivity() {
        var criteria = SearchCriteria()
        criteria.text = "report"
        #expect(FileMatcher(criteria: criteria).matchesName("Final_REPORT.docx"))
        criteria.caseSensitive = true
        #expect(!FileMatcher(criteria: criteria).matchesName("Final_REPORT.docx"))
    }

    @Test func hiddenPathDetection() {
        #expect(FileMatcher.isHiddenPath("/Users/me/.config/app/settings.json"))
        #expect(!FileMatcher.isHiddenPath("/Users/me/Documents/settings.json"))
    }

    @Test func typeScriptIsClassifiedAsCode() {
        #expect(FileKind.classify(contentType: "public.mpeg-2-transport-stream", fileExtension: "ts") == .code)
        #expect(FileKind.classify(contentType: "com.adobe.pdf", fileExtension: "pdf") == .document)
        #expect(FileKind.classify(contentType: "public.folder", fileExtension: "") == .folder)
    }
}
