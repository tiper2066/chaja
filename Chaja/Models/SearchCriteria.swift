import Foundation

nonisolated struct SearchCriteria: Equatable, Sendable {
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
    var whereFrom = ""
    var tags: Set<String> = []
    var includeHidden = false
    var searchPackages = false
    var caseSensitive = false
    var applyExclusions = true
    var scope: SearchScope = .computer

    init() {}

    init(scope: SearchScope) {
        self.scope = scope
    }

    var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 검색어를 공백으로 나눈 단어들. 모든 단어가 들어 있어야 일치한다.
    var words: [String] {
        trimmedText.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    var trimmedWhereFrom: String {
        whereFrom.trimmingCharacters(in: .whitespacesAndNewlines)
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
            || !trimmedWhereFrom.isEmpty || !tags.isEmpty
    }

    /// 조건 없이 맥 전체를 뒤지면 수백만 건이 나오므로, 조건이 없을 땐 특정 위치를 고른 경우에만 검색한다.
    var canSearch: Bool {
        hasConditions || scope != .computer
    }

    /// Spotlight는 숨김 파일과 패키지 내부를 색인하지 않으므로 직접 스캔이 필요하다.
    var needsDirectScan: Bool {
        includeHidden || searchPackages
    }

    /// 사용자 지정 기간이 아니면 날짜 입력값은 검색 결과와 무관하므로 비교에서 뺀다.
    func isSameSearch(as other: SearchCriteria) -> Bool {
        normalizedForComparison == other.normalizedForComparison
    }

    private var normalizedForComparison: SearchCriteria {
        guard datePreset != .custom else { return self }
        var copy = self
        copy.customStartDate = .distantPast
        copy.customEndDate = .distantPast
        return copy
    }

    /// 최근 검색·저장된 검색 목록에 보여줄 한 줄 요약.
    var summary: String {
        var parts: [String] = []
        if !words.isEmpty {
            parts.append("‘\(trimmedText)’" + (textTarget == .nameAndContent ? "(내용 포함)" : ""))
        }
        let groups = ExtensionGroup.presets.filter { extensionGroupIDs.contains($0.id) }.map(\.id)
        let extensionLabels = groups + customExtensions.map { ".\($0)" }
        if !extensionLabels.isEmpty { parts.append(extensionLabels.joined(separator: ", ")) }
        if !kinds.isEmpty {
            parts.append(FileKind.allCases.filter(kinds.contains).map(\.title).joined(separator: ", "))
        }
        switch (minSizeMB, maxSizeMB) {
        case let (min?, max?): parts.append("\(min.formatted())~\(max.formatted())MB")
        case let (min?, nil): parts.append("\(min.formatted())MB 이상")
        case let (nil, max?): parts.append("\(max.formatted())MB 이하")
        case (nil, nil): break
        }
        if datePreset == .custom {
            let range = "\(customStartDate.formatted(date: .numeric, time: .omitted))~\(customEndDate.formatted(date: .numeric, time: .omitted))"
            parts.append("\(dateField.title) \(range)")
        } else if datePreset != .any {
            parts.append("\(dateField.title) \(datePreset.title)")
        }
        if !trimmedWhereFrom.isEmpty { parts.append("출처 ‘\(trimmedWhereFrom)’") }
        if !tags.isEmpty { parts.append(tags.sorted().map { "#\($0)" }.joined(separator: " ")) }
        if scope != .computer { parts.append(scope.title) }
        return parts.isEmpty ? "조건 없음" : parts.joined(separator: " · ")
    }

    private static func bytes(fromMB mb: Double) -> Int64 {
        Int64((mb * 1_048_576).rounded())
    }
}

/// 저장된 검색이 나중에 필드가 늘어나도 읽히도록, 없는 키는 기본값으로 채운다.
extension SearchCriteria: Codable {
    private enum CodingKeys: String, CodingKey {
        case text, textTarget, extensionGroupIDs, customExtensions, kinds, minSizeMB, maxSizeMB
        case datePreset, dateField, customStartDate, customEndDate, whereFrom, tags
        case includeHidden, searchPackages, caseSensitive, applyExclusions, scope
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SearchCriteria()
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? defaults.text
        textTarget = try c.decodeIfPresent(TextTarget.self, forKey: .textTarget) ?? defaults.textTarget
        extensionGroupIDs = try c.decodeIfPresent(Set<String>.self, forKey: .extensionGroupIDs) ?? []
        customExtensions = try c.decodeIfPresent([String].self, forKey: .customExtensions) ?? []
        kinds = try c.decodeIfPresent(Set<FileKind>.self, forKey: .kinds) ?? []
        minSizeMB = try c.decodeIfPresent(Double.self, forKey: .minSizeMB)
        maxSizeMB = try c.decodeIfPresent(Double.self, forKey: .maxSizeMB)
        datePreset = try c.decodeIfPresent(DatePreset.self, forKey: .datePreset) ?? defaults.datePreset
        dateField = try c.decodeIfPresent(DateField.self, forKey: .dateField) ?? defaults.dateField
        customStartDate = try c.decodeIfPresent(Date.self, forKey: .customStartDate) ?? defaults.customStartDate
        customEndDate = try c.decodeIfPresent(Date.self, forKey: .customEndDate) ?? defaults.customEndDate
        whereFrom = try c.decodeIfPresent(String.self, forKey: .whereFrom) ?? ""
        tags = try c.decodeIfPresent(Set<String>.self, forKey: .tags) ?? []
        includeHidden = try c.decodeIfPresent(Bool.self, forKey: .includeHidden) ?? defaults.includeHidden
        searchPackages = try c.decodeIfPresent(Bool.self, forKey: .searchPackages) ?? defaults.searchPackages
        caseSensitive = try c.decodeIfPresent(Bool.self, forKey: .caseSensitive) ?? defaults.caseSensitive
        applyExclusions = try c.decodeIfPresent(Bool.self, forKey: .applyExclusions) ?? defaults.applyExclusions
        scope = try c.decodeIfPresent(SearchScope.self, forKey: .scope) ?? defaults.scope
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        try c.encode(textTarget, forKey: .textTarget)
        try c.encode(extensionGroupIDs, forKey: .extensionGroupIDs)
        try c.encode(customExtensions, forKey: .customExtensions)
        try c.encode(kinds, forKey: .kinds)
        try c.encodeIfPresent(minSizeMB, forKey: .minSizeMB)
        try c.encodeIfPresent(maxSizeMB, forKey: .maxSizeMB)
        try c.encode(datePreset, forKey: .datePreset)
        try c.encode(dateField, forKey: .dateField)
        try c.encode(customStartDate, forKey: .customStartDate)
        try c.encode(customEndDate, forKey: .customEndDate)
        try c.encode(whereFrom, forKey: .whereFrom)
        try c.encode(tags, forKey: .tags)
        try c.encode(includeHidden, forKey: .includeHidden)
        try c.encode(searchPackages, forKey: .searchPackages)
        try c.encode(caseSensitive, forKey: .caseSensitive)
        try c.encode(applyExclusions, forKey: .applyExclusions)
        try c.encode(scope, forKey: .scope)
    }
}
