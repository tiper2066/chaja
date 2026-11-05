import Foundation

/// 직접 스캔한 파일이 검색 조건에 맞는지 판단한다. Spotlight 쿼리와 같은 기준을 따르되 본문 검색은 하지 않는다.
nonisolated struct FileMatcher: Sendable {
    static let resourceKeys: [URLResourceKey] = [
        .nameKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey,
        .contentTypeKey, .localizedTypeDescriptionKey, .isDirectoryKey, .isPackageKey, .tagNamesKey,
    ]

    private let words: [String]
    private let compareOptions: String.CompareOptions
    private let extensions: Set<String>
    private let kinds: Set<FileKind>
    private let minSize: Int64?
    private let maxSize: Int64?
    private let dateBounds: DateBounds?
    private let dateField: DateField
    private let whereFrom: String
    private let tags: Set<String>

    init(criteria: SearchCriteria, now: Date = .now) {
        whereFrom = criteria.trimmedWhereFrom
        tags = Set(criteria.tags.map { $0.lowercased() })
        compareOptions = criteria.caseSensitive ? [.diacriticInsensitive] : [.caseInsensitive, .diacriticInsensitive]
        words = criteria.words.map(\.precomposedStringWithCanonicalMapping)
        extensions = Set(criteria.extensions)
        kinds = criteria.kinds
        minSize = criteria.minSizeBytes
        maxSize = criteria.maxSizeBytes
        dateBounds = criteria.dateBounds(now: now)
        dateField = criteria.dateField
    }

    func matchesName(_ name: String) -> Bool {
        guard !words.isEmpty else { return true }
        let normalized = name.precomposedStringWithCanonicalMapping
        return words.allSatisfy { normalized.range(of: $0, options: compareOptions) != nil }
    }

    func match(_ url: URL) -> FileItem? {
        let name = url.lastPathComponent
        guard matchesName(name) else { return nil }
        if !extensions.isEmpty, !extensions.contains(url.pathExtension.lowercased()) { return nil }

        guard let values = try? url.resourceValues(forKeys: Set(Self.resourceKeys)) else { return nil }
        let isFolder = (values.isDirectory ?? false) && !(values.isPackage ?? false)
        let item = FileItem(
            url: url,
            name: values.name ?? name,
            size: values.fileSize.map(Int64.init),
            created: values.creationDate,
            modified: values.contentModificationDate,
            contentType: values.contentType?.identifier,
            kindDescription: values.localizedTypeDescription,
            isFolder: isFolder
        )

        if !kinds.isEmpty {
            guard let kind = item.kind, kinds.contains(kind) else { return nil }
        }
        if minSize != nil || maxSize != nil {
            guard let size = item.size else { return nil }
            if let minSize, size < minSize { return nil }
            if let maxSize, size > maxSize { return nil }
        }
        if let dateBounds {
            let date = dateField == .modified ? item.modified : item.created
            guard let date, dateBounds.contains(date) else { return nil }
        }
        if !tags.isEmpty {
            let fileTags = Set((values.tagNames ?? []).map { $0.lowercased() })
            guard !fileTags.isDisjoint(with: tags) else { return nil }
        }
        if !whereFrom.isEmpty {
            let sources = FileMetadata.whereFroms(of: url)
            guard sources.contains(where: { $0.range(of: whereFrom, options: [.caseInsensitive, .diacriticInsensitive]) != nil })
            else { return nil }
        }
        return item
    }

    static func isHiddenPath(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0.hasPrefix(".") }
    }
}
