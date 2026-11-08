import AppKit
import Observation

/// 분석 창의 상태. 도구(중복 파일 / 비슷한 이미지)마다 따로 두어 탭을 바꿔도 결과가 남는다.
@Observable
final class AnalysisCenter {
    static let windowID = "analysis"

    var tool: AnalysisTool = .duplicates
    let duplicates = AnalysisSession(tool: .duplicates)
    let similarImages = AnalysisSession(tool: .similarImages)

    func session(for tool: AnalysisTool) -> AnalysisSession {
        switch tool {
        case .duplicates: duplicates
        case .similarImages: similarImages
        }
    }
}

@Observable
final class AnalysisSession {
    enum Phase: Equatable {
        case idle, running, finished
    }

    /// 폴더를 직접 훑을 때 모으는 파일 상한.
    static let folderFileLimit = 200_000

    let tool: AnalysisTool
    var target: AnalysisTarget = .searchResults
    var minimumSize: DuplicateMinimumSize = .any
    var similarity: SimilarityLevel = .similar
    /// 휴지통으로 보낼 파일 경로.
    var marked: Set<String> = []

    private(set) var phase: Phase = .idle
    private(set) var progress: AnalysisProgress?
    private(set) var groups: [FileGroup] = []
    private(set) var examined = 0
    private(set) var skipped = 0
    private(set) var elapsed: Duration?
    /// 검색 결과가 상한에서 잘렸거나 폴더 파일이 너무 많아 일부만 분석했는지.
    private(set) var wasTruncated = false
    private(set) var errorMessage: String?

    private var task: Task<Void, Never>?
    private var generation = 0

    init(tool: AnalysisTool) {
        self.tool = tool
    }

    // MARK: - 실행

    func start(searchResults: [FileItem], resultsTruncated: Bool) {
        cancel()
        generation += 1
        let generation = generation
        phase = .running
        groups = []
        marked = []
        examined = 0
        skipped = 0
        elapsed = nil
        errorMessage = nil
        wasTruncated = false
        progress = AnalysisProgress(message: "준비 중…", fraction: nil)

        let tool = tool
        let target = target
        let minimumSize = minimumSize.rawValue
        let similarity = similarity
        let started = ContinuousClock.now
        let report: @Sendable (AnalysisProgress) -> Void = { [weak self] progress in
            Task { @MainActor in self?.update(progress, generation: generation) }
        }

        task = Task { [weak self] in
            do {
                var items: [FileItem]
                var truncated = false
                switch target {
                case .searchResults:
                    items = searchResults
                    truncated = resultsTruncated
                case .folder(let url):
                    (items, truncated) = await Self.collectFiles(in: url, imagesOnly: tool == .similarImages, report: report)
                }
                items.removeAll(where: \.isFolder)

                let result: AnalysisReport
                switch tool {
                case .duplicates:
                    result = try await DuplicateFinder.findDuplicates(in: items, minimumSize: minimumSize, progress: report)
                case .similarImages:
                    let images = items.filter { $0.kind == .image }
                    truncated = truncated || images.count > SimilarImageFinder.imageLimit
                    result = try await SimilarImageFinder.findSimilar(in: images, level: similarity, progress: report)
                }
                self?.finish(result, truncated: truncated, elapsed: .now - started, generation: generation)
            } catch is CancellationError {
                return
            } catch {
                self?.fail(error, generation: generation)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if phase == .running {
            phase = .idle
            progress = nil
        }
    }

    private static func collectFiles(in folder: URL, imagesOnly: Bool,
                                     report: @Sendable (AnalysisProgress) -> Void) async -> ([FileItem], Bool) {
        var criteria = SearchCriteria()
        criteria.scope = .folder(folder)
        if imagesOnly { criteria.kinds = [.image] }
        var files: [FileItem] = []
        for await batch in FileSystemScanner.scan(criteria: criteria, exclusions: AppSettings.exclusionRules,
                                                  limit: folderFileLimit) {
            files.append(contentsOf: batch.lazy.filter { !$0.isFolder })
            report(AnalysisProgress(message: "파일 목록 만드는 중 (\(files.count.formatted())개)", fraction: nil))
        }
        return (files, files.count >= folderFileLimit)
    }

    private func update(_ progress: AnalysisProgress, generation: Int) {
        guard generation == self.generation, phase == .running else { return }
        self.progress = progress
    }

    private func finish(_ report: AnalysisReport, truncated: Bool, elapsed: Duration, generation: Int) {
        guard generation == self.generation else { return }
        groups = report.groups
        examined = report.examined
        skipped = report.skipped
        wasTruncated = truncated
        self.elapsed = elapsed
        progress = nil
        phase = .finished
        task = nil
        // 내용이 똑같은 중복은 원본 하나만 남기도록 미리 표시해 둔다. 비슷한 이미지는 사용자가 직접 고른다.
        if tool == .duplicates { keepFirstInEveryGroup() }
    }

    private func fail(_ error: Error, generation: Int) {
        guard generation == self.generation else { return }
        errorMessage = error.localizedDescription
        progress = nil
        phase = .finished
        task = nil
    }

    // MARK: - 남길 파일 고르기

    func isMarked(_ item: FileItem) -> Bool { marked.contains(item.path) }

    /// 묶음마다 최소 하나는 남아 있어야 한다.
    func toggleMark(_ item: FileItem, in group: FileGroup) {
        if marked.contains(item.path) {
            marked.remove(item.path)
        } else if group.files.contains(where: { $0.path != item.path && !marked.contains($0.path) }) {
            marked.insert(item.path)
        } else {
            NSSound.beep()
        }
    }

    func keepOnly(_ item: FileItem, in group: FileGroup) {
        for file in group.files {
            if file.path == item.path { marked.remove(file.path) } else { marked.insert(file.path) }
        }
    }

    func keepFirstInEveryGroup() {
        marked = Set(groups.flatMap { $0.files.dropFirst().map(\.path) })
    }

    func keepNewestInEveryGroup() {
        marked = []
        for group in groups {
            guard let newest = group.files.max(by: { ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast) }) else { continue }
            keepOnly(newest, in: group)
        }
    }

    func clearMarks() {
        marked = []
    }

    var markedItems: [FileItem] {
        groups.flatMap(\.files).filter { marked.contains($0.path) }
    }

    var markedBytes: Int64 {
        markedItems.compactMap(\.size).reduce(0, +)
    }

    var duplicateFileCount: Int {
        groups.reduce(0) { $0 + $1.files.count - 1 }
    }

    var reclaimableBytes: Int64 {
        groups.reduce(0) { $0 + DuplicateFinder.wastedBytes($1) }
    }

    // MARK: - 휴지통

    /// 표시한 파일을 휴지통으로 옮기고, 실제로 옮겨진 경로를 돌려준다.
    func trashMarked() async -> Set<String> {
        let urls = markedItems.map(\.url)
        guard !urls.isEmpty else { return [] }
        let failed: Bool
        do {
            _ = try await NSWorkspace.shared.recycle(urls)
            failed = false
        } catch {
            failed = true
        }
        // 일부만 실패해도 recycle은 오류만 돌려주므로, 원래 자리에 남았는지로 판단한다.
        let removed = Set(urls.map(\.path).filter { !FileManager.default.fileExists(atPath: $0) })
        if failed {
            NSSound.beep()
            errorMessage = "일부 파일을 휴지통으로 옮기지 못했어요."
        }
        remove(paths: removed)
        return removed
    }

    func remove(paths: Set<String>) {
        guard !paths.isEmpty else { return }
        marked.subtract(paths)
        groups = groups.compactMap { group in
            var group = group
            group.files.removeAll { paths.contains($0.path) }
            return group.files.count > 1 ? group : nil
        }
        // 묶음에 하나만 남지 않도록, 표시만 남은 묶음은 첫 파일을 살린다.
        for group in groups where group.files.allSatisfy({ marked.contains($0.path) }) {
            marked.remove(group.files[0].path)
        }
    }
}
