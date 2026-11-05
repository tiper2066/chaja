import AppKit

/// 인스펙터와 직접 스캔에서 필요할 때만 읽는 추가 메타데이터.
nonisolated enum FileMetadata {
    static func tags(of url: URL) -> [String] {
        (try? url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
    }

    /// 다운로드한 앱(브라우저·메신저)이 기록한 출처 URL. Spotlight 색인과 무관하게 확장 속성에서 직접 읽는다.
    static func whereFroms(of url: URL) -> [String] {
        let name = "com.apple.metadata:kMDItemWhereFroms"
        let path = url.path
        let size = getxattr(path, name, nil, 0, 0, 0)
        guard size > 0 else { return [] }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, 0) }
        guard read == size,
              let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] else { return [] }
        return list.filter { !$0.isEmpty }
    }
}

/// Finder 태그 목록. 기본 색상 태그 7개에, Spotlight에서 찾은 사용자 태그를 더한다.
struct FinderTag: Identifiable, Hashable {
    let name: String
    let color: NSColor?
    var id: String { name }

    static var standard: [FinderTag] {
        let labels = NSWorkspace.shared.fileLabels
        let colors = NSWorkspace.shared.fileLabelColors
        return labels.indices.dropFirst().map { FinderTag(name: labels[$0], color: colors[$0]) }
    }
}

final class TagCatalog {
    private var query: NSMetadataQuery?
    private var observer: NSObjectProtocol?

    /// 태그가 붙은 파일을 찾아 사용된 태그 이름을 모은다. 태그를 쓰는 파일은 보통 많지 않아 전부 읽는다.
    func loadUsedTags(completion: @escaping @MainActor ([String]) -> Void) {
        let query = NSMetadataQuery()
        query.predicate = NSPredicate(fromMetadataQueryString: #"kMDItemUserTags == "*""#)
        query.searchScopes = [NSMetadataQueryLocalComputerScope]
        query.valueListAttributes = ["kMDItemUserTags"]
        self.query = query
        observer = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let query = self.query else { return }
                query.stop()
                var names = Set<String>()
                for index in 0..<min(query.resultCount, 20_000) {
                    let tags = query.value(ofAttribute: "kMDItemUserTags", forResultAt: index) as? [String] ?? []
                    names.formUnion(tags.filter { !$0.isEmpty })
                }
                if let observer = self.observer { NotificationCenter.default.removeObserver(observer) }
                self.observer = nil
                self.query = nil
                completion(names.sorted())
            }
        }
        query.start()
    }
}
