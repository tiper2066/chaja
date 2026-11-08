import Foundation

/// NSMetadataQuery로 Spotlight 인덱스를 조회한다. 결과는 모이는 대로 배치로 넘기고, 상한에 닿으면 쿼리를 멈춘다.
final class SpotlightSearchEngine {
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var delivered = 0
    private var limit = 0
    private var onBatch: (([FileItem]) -> Void)?
    private var onFinish: ((_ reachedLimit: Bool) -> Void)?

    var isRunning: Bool { query != nil }

    @discardableResult
    func start(queryString: String, scope: SearchScope, limit: Int,
               onBatch: @escaping ([FileItem]) -> Void,
               onFinish: @escaping (_ reachedLimit: Bool) -> Void) -> Bool {
        stop()
        guard let predicate = NSPredicate(fromMetadataQueryString: queryString) else { return false }

        let query = NSMetadataQuery()
        query.predicate = predicate
        query.searchScopes = scope.url.map { [$0] } ?? [NSMetadataQueryLocalComputerScope]
        query.notificationBatchingInterval = 0.1
        // 미리 지정한 속성은 결과와 함께 모아 두므로, 항목마다 Spotlight에 따로 묻지 않아도 된다(1만 개 기준 20.3초 → 1.7초).
        query.valueListAttributes = Self.attributes

        self.query = query
        self.limit = limit
        self.delivered = 0
        self.onBatch = onBatch
        self.onFinish = onFinish

        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .NSMetadataQueryGatheringProgress, object: query, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.collect(finished: false) }
            },
            center.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.collect(finished: true) }
            },
        ]
        return query.start()
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        query?.stop()
        query = nil
        onBatch = nil
        onFinish = nil
    }

    private func collect(finished: Bool) {
        guard let query else { return }
        query.disableUpdates()
        let count = query.resultCount
        let end = min(count, limit)
        var batch: [FileItem] = []
        if delivered < end {
            batch.reserveCapacity(end - delivered)
            for index in delivered..<end {
                // 경로는 값 목록으로 미리 받을 수 없어 항목에서 직접 읽는다.
                guard let item = query.result(at: index) as? NSMetadataItem,
                      let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
                batch.append(FileItem(path: path, spotlightValue: { query.value(ofAttribute: $0, forResultAt: index) }))
            }
            delivered = end
        }
        query.enableUpdates()

        let onBatch = onBatch
        let onFinish = onFinish
        let reachedLimit = count >= limit
        if reachedLimit || finished { stop() }
        if !batch.isEmpty { onBatch?(batch) }
        if reachedLimit || finished { onFinish?(reachedLimit) }
    }
}

extension SpotlightSearchEngine {
    /// 쿼리 결과를 한 번에 모아 돌려준다. 인스펙터처럼 결과가 적은 짧은 조회용.
    static func collect(queryString: String, scope: SearchScope = .computer,
                        limit: Int) async -> (items: [FileItem], reachedLimit: Bool) {
        let engine = SpotlightSearchEngine()
        var items: [FileItem] = []
        let reachedLimit = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let started = engine.start(queryString: queryString, scope: scope, limit: limit,
                                       onBatch: { items += $0 },
                                       onFinish: { continuation.resume(returning: $0) })
            if !started { continuation.resume(returning: false) }
        }
        return (items, reachedLimit)
    }

    static let attributes = [
        NSMetadataItemFSNameKey, NSMetadataItemFSSizeKey,
        NSMetadataItemFSCreationDateKey, NSMetadataItemFSContentChangeDateKey,
        NSMetadataItemContentTypeKey, NSMetadataItemKindKey,
    ]
}

extension FileItem {
    nonisolated init(path: String, spotlightValue value: (String) -> Any?) {
        let contentType = value(NSMetadataItemContentTypeKey) as? String
        self.init(
            url: URL(fileURLWithPath: path),
            name: value(NSMetadataItemFSNameKey) as? String,
            size: (value(NSMetadataItemFSSizeKey) as? NSNumber)?.int64Value,
            created: value(NSMetadataItemFSCreationDateKey) as? Date,
            modified: value(NSMetadataItemFSContentChangeDateKey) as? Date,
            contentType: contentType,
            kindDescription: value(NSMetadataItemKindKey) as? String,
            isFolder: contentType == "public.folder"
        )
    }
}
