import Foundation

nonisolated struct SearchCriteria: Equatable, Codable, Sendable {
    enum TextTarget: String, CaseIterable, Identifiable, Codable, Sendable {
        case name, nameAndContent

        var id: String { rawValue }

        var title: String {
            switch self {
            case .name: "이름"
            case .nameAndContent: "이름 + 내용"
            }
        }
    }

    var text = ""
    var textTarget: TextTarget = .name
    var extensionGroupIDs: Set<String> = []
    var customExtensions: [String] = []
    var kinds: Set<FileKind> = []
    var minSizeMB: Double?
    var maxSizeMB: Double?
    var datePreset: DatePreset = .any
    var dateField: DateField = .modified
    var customStartDate: Date = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now
    var customEndDate: Date = .now
    var includeHidden = false
    var searchPackages = false
    var caseSensitive = false
    var scope: SearchScope = .computer

    var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 검색어를 공백으로 나눈 단어들. 모든 단어가 들어 있어야 일치한다.
    var words: [String] {
        trimmedText.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    var extensions: [String] {
        var seen = Set<String>()
        let fromGroups = ExtensionGroup.presets
            .filter { extensionGroupIDs.contains($0.id) }
            .flatMap(\.extensions)
        return (fromGroups + customExtensions).filter { seen.insert($0).inserted }
    }

    var minSizeBytes: Int64? { minSizeMB.map(Self.bytes(fromMB:)) }
    var maxSizeBytes: Int64? { maxSizeMB.map(Self.bytes(fromMB:)) }

    func dateBounds(now: Date = .now, calendar: Calendar = .current) -> DateBounds? {
        DateBounds.make(preset: datePreset, customStart: customStartDate, customEnd: customEndDate,
                        now: now, calendar: calendar)
    }

    var hasConditions: Bool {
        !words.isEmpty || !extensions.isEmpty || !kinds.isEmpty
            || minSizeMB != nil || maxSizeMB != nil || datePreset != .any
    }

    /// 조건 없이 맥 전체를 뒤지면 수백만 건이 나오므로, 조건이 없을 땐 특정 위치를 고른 경우에만 검색한다.
    var canSearch: Bool {
        hasConditions || scope != .computer
    }

    /// Spotlight는 숨김 파일과 패키지 내부를 색인하지 않으므로 직접 스캔이 필요하다.
    var needsDirectScan: Bool {
        includeHidden || searchPackages
    }

    private static func bytes(fromMB mb: Double) -> Int64 {
        Int64((mb * 1_048_576).rounded())
    }
}
