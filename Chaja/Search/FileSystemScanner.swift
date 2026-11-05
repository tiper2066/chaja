import Foundation

/// Spotlight가 색인하지 않는 숨김 파일·패키지 내부를 찾기 위해 디스크를 직접 순회한다.
nonisolated enum FileSystemScanner {
    /// 맥 전체를 순회할 때 건너뛰는 경로. `/System/Volumes/Data`는 루트와 같은 내용이라 중복된다.
    static let skippedRootPaths: Set<String> = ["/System", "/dev", "/cores", "/private/var/vm", "/Volumes/Recovery"]

    static func scan(criteria: SearchCriteria, exclusions: ExclusionRules = .none, limit: Int) -> AsyncStream<[FileItem]> {
        let roots = [criteria.scope.url ?? URL(fileURLWithPath: "/")]
        let options: FileManager.DirectoryEnumerationOptions = [
            criteria.includeHidden ? [] : .skipsHiddenFiles,
            criteria.searchPackages ? [] : .skipsPackageDescendants,
        ]
        let matcher = FileMatcher(criteria: criteria)

        return AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                var batch: [FileItem] = []
                var found = 0
                var lastFlush = ContinuousClock.now

                rootLoop: for root in roots {
                    guard let enumerator = FileManager.default.enumerator(
                        at: root, includingPropertiesForKeys: FileMatcher.resourceKeys,
                        options: options, errorHandler: { _, _ in true }
                    ) else { continue }

                    while let url = enumerator.nextObject() as? URL {
                        if Task.isCancelled { break rootLoop }
                        let path = url.path
                        if skippedRootPaths.contains(path) || exclusions.excludes(path: path) {
                            enumerator.skipDescendants()
                            continue
                        }
                        guard let item = matcher.match(url) else { continue }
                        batch.append(item)
                        found += 1
                        if found >= limit { break rootLoop }
                        if batch.count >= 200 || ContinuousClock.now - lastFlush > .milliseconds(200) {
                            continuation.yield(batch)
                            batch.removeAll(keepingCapacity: true)
                            lastFlush = .now
                        }
                    }
                }
                if !batch.isEmpty { continuation.yield(batch) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
