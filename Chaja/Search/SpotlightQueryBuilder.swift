import Foundation

/// 검색 조건을 Spotlight 쿼리 문자열(`mdfind`와 같은 문법)로 바꾼다.
/// 같은 문자열을 `mdfind`에 넣어 결과를 비교·검증할 수 있다.
nonisolated enum SpotlightQueryBuilder {
    static let matchEverything = #"kMDItemContentTypeTree == "public.item""#

    static func queryString(for criteria: SearchCriteria, now: Date = .now, calendar: Calendar = .current) -> String {
        var clauses: [String] = []
        // c: 대소문자 무시, d: 발음 구별·유니코드 정규화(한글 자모 NFC/NFD) 차이 무시
        let modifiers = criteria.caseSensitive ? "d" : "cd"

        for word in criteria.words {
            let value = escape(word)
            let nameClause = #"kMDItemFSName == "*\#(value)*"\#(modifiers)"#
            switch criteria.textTarget {
            case .name:
                clauses.append(nameClause)
            case .nameAndContent:
                // 본문은 단어 시작 일치(w)가 부분 일치보다 20배가량 빠르다.
                clauses.append(#"(\#(nameClause) || kMDItemTextContent == "\#(value)*"\#(modifiers)w)"#)
            }
        }

        let extensions = criteria.extensions
        if !extensions.isEmpty {
            let parts = extensions.map { #"kMDItemFSName == "*.\#(escape($0))"c"# }
            clauses.append(group(parts))
        }

        if !criteria.kinds.isEmpty {
            let parts = FileKind.allCases.filter(criteria.kinds.contains).map(\.queryClause)
            clauses.append(group(parts))
        }

        if let min = criteria.minSizeBytes {
            clauses.append("kMDItemFSSize >= \(min)")
        }
        if let max = criteria.maxSizeBytes {
            clauses.append("kMDItemFSSize <= \(max)")
        }

        if let bounds = criteria.dateBounds(now: now, calendar: calendar) {
            let attribute = criteria.dateField.spotlightAttribute
            if let lower = bounds.lower {
                clauses.append("\(attribute) >= \(timeLiteral(lower))")
            }
            if let upper = bounds.upper {
                clauses.append("\(attribute) < \(timeLiteral(upper))")
            }
        }

        return clauses.isEmpty ? matchEverything : clauses.joined(separator: " && ")
    }

    static func escape(_ value: String) -> String {
        var result = ""
        for character in value {
            if character == "\\" || character == "\"" || character == "*" || character == "?" {
                result.append("\\")
            }
            result.append(character)
        }
        return result
    }

    private static func group(_ parts: [String]) -> String {
        parts.count == 1 ? parts[0] : "(" + parts.joined(separator: " || ") + ")"
    }

    private static func timeLiteral(_ date: Date) -> String {
        "$time.iso(\(date.formatted(.iso8601)))"
    }
}
