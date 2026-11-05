import AppKit
import Observation

@Observable
final class SearchModel {
    enum Phase: Equatable {
        case idle, searching, finished
    }

    enum SortField: String, CaseIterable, Identifiable {
        case name, size, modified, created, kind

        var id: String { rawValue }

        var title: String {
            switch self {
            case .name: "이름"
            case .size: "크기"
            case .modified: "수정일"
            case .created: "생성일"
            case .kind: "종류"
            }
        }
    }

    static let defaultResultLimit = 10_000

    var criteria = SearchCriteria()
    var selection: Set<FileItem.ID> = []
    var sortOrder: [KeyPathComparator<FileItem>] = [SearchModel.comparator(for: .name, order: .forward)] {
        didSet { applySort() }
    }
    var resultLimit = SearchModel.defaultResultLimit
    var quickLookURL: URL?
    private(set) var searchFocusRequest = 0

    private(set) var results: [FileItem] = []
    private(set) var phase: Phase = .idle
    private(set) var reachedLimit = false
    private(set) var isScanningDisk = false
    private(set) var elapsed: Duration?
    private(set) var firstResultElapsed: Duration?
    private(set) var hasFullDiskAccess = PermissionService.hasFullDiskAccess

    private let spotlight = SpotlightSearchEngine()
    private var scanTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var seenPaths = Set<String>()
    private var startedAt = ContinuousClock.now
    private var pendingEngines = 0
    private var searchGeneration = 0

    // MARK: - 검색

    func scheduleSearch() {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            search()
        }
    }

    func search() {
        debounceTask?.cancel()
        cancelEngines()
        searchGeneration += 1
        results = []
        selection = []
        seenPaths = []
        reachedLimit = false
        elapsed = nil
        firstResultElapsed = nil

        guard criteria.canSearch else {
            phase = .idle
            return
        }

        let criteria = criteria
        let generation = searchGeneration
        phase = .searching
        startedAt = .now
        pendingEngines = criteria.needsDirectScan ? 2 : 1

        let queryString = SpotlightQueryBuilder.queryString(for: criteria)
        let started = spotlight.start(
            queryString: queryString, scope: criteria.scope, limit: resultLimit,
            onBatch: { [weak self] batch in self?.append(batch, generation: generation) },
            onFinish: { [weak self] limitHit in
                if limitHit { self?.markLimitReached(generation: generation) }
                self?.engineFinished(generation: generation)
            }
        )
        if !started { engineFinished(generation: generation) }

        if criteria.needsDirectScan {
            isScanningDisk = true
            let limit = resultLimit
            scanTask = Task { [weak self] in
                for await batch in FileSystemScanner.scan(criteria: criteria, limit: limit) {
                    self?.append(batch, generation: generation)
                }
                guard let self, generation == self.searchGeneration else { return }
                self.isScanningDisk = false
                self.engineFinished(generation: generation)
            }
        }
    }

    func cancel() {
        debounceTask?.cancel()
        guard phase == .searching else { return }
        cancelEngines()
        finish()
    }

    func resetFilters() {
        criteria = SearchCriteria()
    }

    func refreshPermissions() {
        hasFullDiskAccess = PermissionService.hasFullDiskAccess
    }

    func requestSearchFocus() {
        searchFocusRequest += 1
    }

    func toggleQuickLook() {
        quickLookURL = quickLookURL == nil ? selectedItems.first?.url : nil
    }

    private func cancelEngines() {
        spotlight.stop()
        scanTask?.cancel()
        scanTask = nil
        isScanningDisk = false
        pendingEngines = 0
    }

    private func append(_ batch: [FileItem], generation: Int) {
        guard generation == searchGeneration, phase == .searching else { return }
        let includeHidden = criteria.includeHidden
        var fresh = batch.filter { item in
            if !includeHidden, FileMatcher.isHiddenPath(item.path) { return false }
            return seenPaths.insert(item.id).inserted
        }
        guard !fresh.isEmpty else { return }

        if firstResultElapsed == nil { firstResultElapsed = ContinuousClock.now - startedAt }
        let room = resultLimit - results.count
        if fresh.count > room {
            fresh = Array(fresh.prefix(room))
            reachedLimit = true
        }
        results.append(contentsOf: fresh)
        // 대량 결과를 배치마다 다시 정렬하면 느려지므로 일정 개수까지만 즉시 정렬하고 나머지는 끝날 때 한 번 정렬한다.
        if results.count <= 3_000 { applySort() }

        if reachedLimit {
            cancelEngines()
            finish()
        }
    }

    private func markLimitReached(generation: Int) {
        guard generation == searchGeneration else { return }
        reachedLimit = true
    }

    private func engineFinished(generation: Int) {
        guard generation == searchGeneration, phase == .searching else { return }
        pendingEngines -= 1
        if pendingEngines <= 0 { finish() }
    }

    private func finish() {
        phase = .finished
        elapsed = ContinuousClock.now - startedAt
        applySort()
    }

    private func applySort() {
        results.sort(using: sortOrder)
    }

    // MARK: - 정렬

    var sortField: SortField {
        get {
            guard let current = sortOrder.first else { return .name }
            return SortField.allCases.first { Self.comparator(for: $0, order: current.order) == current } ?? .name
        }
        set { sortOrder = [Self.comparator(for: newValue, order: sortAscending ? .forward : .reverse)] }
    }

    var sortAscending: Bool {
        get { sortOrder.first?.order != .reverse }
        set { sortOrder = [Self.comparator(for: sortField, order: newValue ? .forward : .reverse)] }
    }

    static func comparator(for field: SortField, order: SortOrder) -> KeyPathComparator<FileItem> {
        switch field {
        case .name: KeyPathComparator(\FileItem.name, comparator: .localizedStandard, order: order)
        case .size: KeyPathComparator(\FileItem.sortSize, order: order)
        case .modified: KeyPathComparator(\FileItem.sortModified, order: order)
        case .created: KeyPathComparator(\FileItem.sortCreated, order: order)
        case .kind: KeyPathComparator(\FileItem.kindDescription, comparator: .localizedStandard, order: order)
        }
    }

    // MARK: - 선택 항목과 파일 동작

    var selectedItems: [FileItem] {
        guard !selection.isEmpty else { return [] }
        return results.filter { selection.contains($0.id) }
    }

    func items(for ids: Set<FileItem.ID>) -> [FileItem] {
        results.filter { ids.contains($0.id) }
    }

    func open(_ items: [FileItem]) {
        items.forEach { NSWorkspace.shared.open($0.url) }
    }

    func revealInFinder(_ items: [FileItem]) {
        guard !items.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(items.map(\.url))
    }

    func copyPaths(_ items: [FileItem]) {
        guard !items.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(items.map(\.path).joined(separator: "\n"), forType: .string)
    }

    func moveToTrash(_ items: [FileItem]) async {
        guard !items.isEmpty else { return }
        do {
            let trashed = try await NSWorkspace.shared.recycle(items.map(\.url))
            let removed = Set(trashed.keys.map(\.path))
            results.removeAll { removed.contains($0.id) }
            selection.subtract(removed)
        } catch {
            NSSound.beep()
        }
    }
}
