import Foundation
import Synchronization

/// 중복 파일 또는 비슷한 이미지 한 묶음. 첫 번째 파일이 기본으로 남길 파일이다.
nonisolated struct FileGroup: Identifiable, Hashable, Sendable {
    let id: String
    var files: [FileItem]

    var totalSize: Int64 { files.compactMap(\.size).reduce(0, +) }
}

nonisolated struct AnalysisReport: Sendable {
    var groups: [FileGroup]
    /// 실제로 비교한 파일 수.
    var examined: Int
    /// 읽을 수 없거나 iCloud에만 있어 건너뛴 파일 수.
    var skipped: Int
}

nonisolated struct AnalysisProgress: Equatable, Sendable {
    var message: String
    /// nil이면 진행률을 알 수 없는 단계.
    var fraction: Double?
}

nonisolated enum AnalysisTool: String, CaseIterable, Identifiable, Sendable {
    case duplicates, similarImages

    var id: String { rawValue }

    var title: String {
        switch self {
        case .duplicates: "중복 파일"
        case .similarImages: "비슷한 이미지"
        }
    }

    var symbol: String {
        switch self {
        case .duplicates: "doc.on.doc"
        case .similarImages: "photo.on.rectangle.angled"
        }
    }
}

nonisolated enum AnalysisTarget: Hashable, Sendable {
    case searchResults
    case folder(URL)
}

nonisolated enum DuplicateMinimumSize: Int64, CaseIterable, Identifiable, Sendable {
    case any = 1
    case kb100 = 100_000
    case mb1 = 1_000_000
    case mb10 = 10_000_000
    case mb100 = 100_000_000

    var id: Int64 { rawValue }

    var title: String {
        switch self {
        case .any: "전체"
        case .kb100: "100KB 이상"
        case .mb1: "1MB 이상"
        case .mb10: "10MB 이상"
        case .mb100: "100MB 이상"
        }
    }
}

/// 비슷한 정도. 값은 Vision 특징값 사이의 거리(제곱 유클리드 거리) 상한이다.
/// 1600px 사진 기준 측정: 크기 축소·저화질 재압축·85% 자르기·좌우 반전 사본 0.003~0.12, 같은 디자인의 색상 변형 0.13, 밝기만 다른 같은 그림 0.23, 서로 다른 사진 0.3 이상.
nonisolated enum SimilarityLevel: String, CaseIterable, Identifiable, Sendable {
    case nearlyIdentical, similar, loose

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nearlyIdentical: "거의 같음"
        case .similar: "비슷함"
        case .loose: "느슨하게"
        }
    }

    var detail: String {
        switch self {
        case .nearlyIdentical: "크기·화질만 다른 사본"
        case .similar: "살짝 자르거나 보정한 사진까지"
        case .loose: "같은 장면을 여러 번 찍은 사진까지"
        }
    }

    var threshold: Float {
        switch self {
        case .nearlyIdentical: 0.10
        case .similar: 0.18
        case .loose: 0.28
        }
    }
}

/// `lstat`으로 읽은 파일 정보. Spotlight 값은 늦게 갱신될 수 있어 분석은 항상 실제 파일 기준으로 한다.
nonisolated struct FileStat: Hashable, Sendable {
    /// iCloud에서 내려받지 않은 파일(내용 없음). 읽으면 다운로드가 시작된다.
    private static let datalessFlag: UInt32 = 0x4000_0000

    let size: Int64
    let device: Int32
    let inode: UInt64
    let modified: TimeInterval
    let isRegularFile: Bool
    let isDataless: Bool

    init?(path: String) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        size = Int64(info.st_size)
        device = info.st_dev
        inode = info.st_ino
        modified = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9
        isRegularFile = (info.st_mode & S_IFMT) == S_IFREG
        isDataless = info.st_flags & Self.datalessFlag != 0
    }

    var identity: FileIdentity { FileIdentity(device: device, inode: inode) }
}

/// 하드 링크는 경로가 달라도 같은 파일이다.
nonisolated struct FileIdentity: Hashable, Sendable {
    let device: Int32
    let inode: UInt64
}

/// 여러 작업이 함께 올리는 진행 카운터.
nonisolated final class ProgressCounter: Sendable {
    private let storage = Atomic<Int64>(0)

    func add(_ amount: Int64) {
        storage.add(amount, ordering: .relaxed)
    }

    var value: Int64 { storage.load(ordering: .relaxed) }
}

nonisolated enum AnalysisConcurrency {
    /// 디스크 읽기와 Vision 추론을 몇 개씩 동시에 돌릴지.
    static let width = 4

    /// 순서를 유지하며 동시에 `width`개씩 변환한다. 하나라도 취소되면 전체를 취소한다.
    static func map<T: Sendable, R: Sendable>(
        _ items: [T], width: Int = AnalysisConcurrency.width,
        onEach: (() -> Void)? = nil,
        _ transform: @escaping @Sendable (T) async throws -> R
    ) async throws -> [R] {
        guard !items.isEmpty else { return [] }
        return try await withThrowingTaskGroup(of: (Int, R).self) { group in
            var results = [R?](repeating: nil, count: items.count)
            var next = 0
            for _ in 0..<min(width, items.count) {
                let index = next
                group.addTask { (index, try await transform(items[index])) }
                next += 1
            }
            while let (index, result) = try await group.next() {
                results[index] = result
                onEach?()
                if next < items.count {
                    let index = next
                    group.addTask { (index, try await transform(items[index])) }
                    next += 1
                }
            }
            return results.map { $0! }
        }
    }

    /// 작업하는 동안 주기적으로 카운터 값을 진행률로 알린다.
    static func reporting<R>(
        _ counter: ProgressCounter, total: Int64,
        message: @escaping @Sendable (Int64) -> String,
        to progress: @escaping @Sendable (AnalysisProgress) -> Void,
        _ body: () async throws -> R
    ) async throws -> R {
        let poller = Task {
            while !Task.isCancelled {
                let done = counter.value
                progress(AnalysisProgress(message: message(done),
                                          fraction: total > 0 ? min(Double(done) / Double(total), 1) : nil))
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        defer { poller.cancel() }
        return try await body()
    }
}
