import Foundation

nonisolated enum DatePreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case any, today, last7Days, last30Days, lastYear, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .any: "전체 기간"
        case .today: "오늘"
        case .last7Days: "최근 7일"
        case .last30Days: "최근 30일"
        case .lastYear: "1년"
        case .custom: "직접 선택"
        }
    }
}

nonisolated enum DateField: String, CaseIterable, Identifiable, Codable, Sendable {
    case modified, created

    var id: String { rawValue }

    var title: String {
        switch self {
        case .modified: "수정일"
        case .created: "생성일"
        }
    }

    var spotlightAttribute: String {
        switch self {
        case .modified: "kMDItemFSContentChangeDate"
        case .created: "kMDItemFSCreationDate"
        }
    }
}

/// 시작 이상, 끝 미만인 반열린 구간. nil은 제한 없음.
nonisolated struct DateBounds: Equatable, Sendable {
    var lower: Date?
    var upper: Date?

    func contains(_ date: Date) -> Bool {
        if let lower, date < lower { return false }
        if let upper, date >= upper { return false }
        return true
    }

    static func make(preset: DatePreset, customStart: Date, customEnd: Date,
                     now: Date = .now, calendar: Calendar = .current) -> DateBounds? {
        switch preset {
        case .any:
            return nil
        case .today:
            return DateBounds(lower: calendar.startOfDay(for: now))
        case .last7Days:
            return DateBounds(lower: calendar.date(byAdding: .day, value: -7, to: now))
        case .last30Days:
            return DateBounds(lower: calendar.date(byAdding: .day, value: -30, to: now))
        case .lastYear:
            return DateBounds(lower: calendar.date(byAdding: .year, value: -1, to: now))
        case .custom:
            let start = calendar.startOfDay(for: min(customStart, customEnd))
            let endDay = calendar.startOfDay(for: max(customStart, customEnd))
            return DateBounds(lower: start, upper: calendar.date(byAdding: .day, value: 1, to: endDay))
        }
    }
}
