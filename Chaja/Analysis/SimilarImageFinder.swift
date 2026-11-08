import Accelerate
import Foundation
import Vision

/// Vision 특징값(이미지마다 768차원 벡터)으로 비슷한 이미지를 묶는다. 특징값 생성은 Neural Engine에서 돈다.
nonisolated enum SimilarImageFinder {
    /// 한 번에 비교할 이미지 상한. 1만 개 비교(행렬곱)는 1초 안쪽이지만 특징값 생성이 이미지당 10ms 남짓 걸린다.
    static let imageLimit = 20_000

    enum FeaturePrintError: Error {
        case unsupportedElementType
    }

    @concurrent
    static func findSimilar(
        in items: [FileItem], level: SimilarityLevel, store: FeaturePrintStore = .shared,
        progress: @escaping @Sendable (AnalysisProgress) -> Void = { _ in }
    ) async throws -> AnalysisReport {
        progress(AnalysisProgress(message: "이미지 확인 중…", fraction: nil))
        let images = uniqueImages(items).prefix(imageLimit)
        let counter = ProgressCounter()
        let total = images.count
        let prints = try await AnalysisConcurrency.reporting(
            counter, total: Int64(total),
            message: { "이미지 특징 분석 중 (\($0.formatted()) / \(total.formatted()))" },
            to: progress
        ) {
            try await featurePrints(for: Array(images), store: store, counter: counter)
        }

        progress(AnalysisProgress(message: "비슷한 이미지 묶는 중…", fraction: nil))
        var analyzedItems: [FileItem] = []
        var vectors: [[Float]] = []
        for (item, vector) in zip(images, prints) {
            guard let vector else { continue }
            analyzedItems.append(item)
            vectors.append(vector)
        }
        let clusters = try clusters(of: vectors, threshold: level.threshold)
        let groups = clusters.map { members -> FileGroup in
            // 파일이 큰 쪽이 보통 해상도·화질이 높아 맨 앞(남길 후보)에 둔다.
            let files = members.map { analyzedItems[$0] }.sorted { ($0.size ?? 0) > ($1.size ?? 0) }
            return FileGroup(id: files[0].path, files: files)
        }
        .sorted { a, b in
            a.files.count != b.files.count ? a.files.count > b.files.count : a.totalSize > b.totalSize
        }
        return AnalysisReport(groups: groups, examined: analyzedItems.count, skipped: total - analyzedItems.count)
    }

    /// `item`과 비슷한 이미지를 `candidates`에서 찾아 가까운 순으로 돌려준다.
    @concurrent
    static func images(similarTo item: FileItem, among candidates: [FileItem], level: SimilarityLevel,
                       store: FeaturePrintStore = .shared) async throws -> [FileItem] {
        let others = uniqueImages(candidates).filter { $0.path != item.path }
        let prints = try await featurePrints(for: [item] + others, store: store)
        guard let target = prints.first ?? nil else { return [] }
        return zip(others, prints.dropFirst())
            .compactMap { other, vector -> (FileItem, Float)? in
                guard let vector else { return nil }
                let distance = squaredDistance(target, vector)
                return distance <= level.threshold ? (other, distance) : nil
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    /// 같은 폴더(하위 폴더 제외)에서 `item`과 비슷한 이미지. 연사·보정본은 보통 한 폴더에 모여 있다.
    @concurrent
    static func imagesInSameFolder(similarTo item: FileItem, level: SimilarityLevel, limit: Int = 300,
                                   store: FeaturePrintStore = .shared) async throws -> [FileItem] {
        var criteria = SearchCriteria()
        criteria.kinds = [.image]
        let matcher = FileMatcher(criteria: criteria)
        let folder = item.url.deletingLastPathComponent()
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: FileMatcher.resourceKeys, options: [.skipsHiddenFiles]
        )) ?? []
        let siblings = urls.lazy.filter { $0.path != item.path }.compactMap(matcher.match).prefix(limit)
        return try await images(similarTo: item, among: Array(siblings), level: level, store: store)
    }

    private static func uniqueImages(_ items: [FileItem]) -> [FileItem] {
        var seen = Set<String>()
        return items.filter { $0.kind == .image && seen.insert($0.path).inserted }
    }

    // MARK: - 특징값

    /// 캐시에 없는 이미지만 Vision으로 분석한다. 읽을 수 없는 이미지와 iCloud에만 있는 이미지는 nil.
    static func featurePrints(for items: [FileItem], store: FeaturePrintStore,
                              counter: ProgressCounter? = nil) async throws -> [[Float]?] {
        let stats = items.map { FileStat(path: $0.path) }
        let cached = await store.vectors(for: zip(items, stats).map { ($0.path, $1) })
        counter?.add(Int64(cached.compactMap { $0 }.count))

        let missing = items.indices.filter { index in
            guard cached[index] == nil, let stat = stats[index] else { return false }
            return stat.isRegularFile && !stat.isDataless
        }
        let computed = try await AnalysisConcurrency.map(missing) { index -> [Float]? in
            defer { counter?.add(1) }
            do {
                return try await featurePrint(of: items[index].url)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return nil
            }
        }

        var result = cached
        var fresh: [(String, FileStat, [Float])] = []
        for (index, vector) in zip(missing, computed) {
            guard let vector, let stat = stats[index] else { continue }
            result[index] = vector
            fresh.append((items[index].path, stat, vector))
        }
        if !fresh.isEmpty { await store.store(fresh) }
        return result
    }

    static func featurePrint(of url: URL) async throws -> [Float] {
        try Task.checkCancellation()
        let observation = try await GenerateImageFeaturePrintRequest().perform(on: url)
        switch observation.elementType {
        case .float:
            return observation.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        case .double:
            return observation.data.withUnsafeBytes { $0.bindMemory(to: Double.self).map(Float.init) }
        default:
            throw FeaturePrintError.unsupportedElementType
        }
    }

    // MARK: - 거리와 묶기

    /// Vision의 `FeaturePrintObservation.distance(to:)`와 같은 값(제곱 유클리드 거리).
    static func squaredDistance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return .infinity }
        return vDSP.distanceSquared(a, b)
    }

    /// 거리가 `threshold` 이하인 이미지끼리 이어서 묶는다(2개 이상인 묶음만).
    /// 모든 쌍의 거리를 ‖a‖² + ‖b‖² − 2a·b 로 바꿔, 행렬곱을 블록 단위로 계산한다.
    static func clusters(of vectors: [[Float]], threshold: Float) throws -> [[Int]] {
        let count = vectors.count
        guard count > 1, let dimension = vectors.first?.count, dimension > 0 else { return [] }
        let usable = vectors.indices.filter { vectors[$0].count == dimension }
        let n = usable.count
        guard n > 1 else { return [] }

        var matrix = [Float]()
        matrix.reserveCapacity(n * dimension)
        for index in usable { matrix.append(contentsOf: vectors[index]) }
        let norms = usable.map { vDSP.sumOfSquares(vectors[$0]) }

        var parent = Array(0..<n)
        func root(_ x: Int) -> Int {
            var x = x
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }

        // 블록마다 [start, n) 열만 계산해 대칭인 아래 삼각형은 건너뛴다.
        let blockRows = 256
        var product = [Float](repeating: 0, count: blockRows * n)
        var pairs: [(Int, Int)] = []
        for start in stride(from: 0, to: n, by: blockRows) {
            try Task.checkCancellation()
            let rows = min(blockRows, n - start)
            let columns = n - start
            matrix.withUnsafeBufferPointer { all in
                product.withUnsafeMutableBufferPointer { out in
                    let block = all.baseAddress! + start * dimension
                    cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans,
                                Int32(rows), Int32(columns), Int32(dimension),
                                1, block, Int32(dimension), block, Int32(dimension),
                                0, out.baseAddress!, Int32(columns))
                }
            }
            product.withUnsafeMutableBufferPointer { out in
                norms.withUnsafeBufferPointer { norms in
                    var minusTwo: Float = -2
                    for row in 0..<rows {
                        let first = row + 1
                        let count = columns - first
                        guard count > 0 else { continue }
                        let i = start + row
                        // 거리² − ‖a‖² = ‖b‖² − 2a·b 를 한 줄씩 벡터 연산으로 구하고, 가장 작은 값이 기준을 넘으면 그 줄은 건너뛴다.
                        let line = out.baseAddress! + row * columns + first
                        vDSP_vsma(line, 1, &minusTwo, norms.baseAddress! + start + first, 1, line, 1, vDSP_Length(count))
                        var minimum: Float = 0
                        vDSP_minv(line, 1, &minimum, vDSP_Length(count))
                        let limit = threshold - norms[i]
                        guard minimum <= limit else { continue }
                        for offset in 0..<count where line[offset] <= limit {
                            pairs.append((i, start + first + offset))
                        }
                    }
                }
            }
            for (i, j) in pairs {
                let a = root(i), b = root(j)
                if a != b { parent[b] = a }
            }
            pairs.removeAll(keepingCapacity: true)
        }

        var members: [Int: [Int]] = [:]
        for index in 0..<n { members[root(index), default: []].append(usable[index]) }
        return members.values.filter { $0.count > 1 }.map { $0.sorted() }.sorted { $0[0] < $1[0] }
    }
}

/// 특징값 캐시. 경로별로 크기·수정 시각이 그대로일 때만 다시 쓴다.
/// `~/Library/Application Support/Chaja/FeaturePrints.plist` (이미지 1만 개 ≈ 30MB)
actor FeaturePrintStore {
    static let shared = FeaturePrintStore(fileURL: URL.applicationSupportDirectory.appending(path: "Chaja/FeaturePrints.plist"))

    /// 특징값 형식(Vision 리비전)이 바뀌면 올린다. 다른 버전의 캐시는 버린다.
    private static let version = 2

    nonisolated private struct Entry: Codable {
        var size: Int64
        var modified: TimeInterval
        var vector: Data
    }

    nonisolated private struct Storage: Codable {
        var version: Int
        var entries: [String: Entry]
    }

    private let fileURL: URL
    private var entries: [String: Entry]?
    private var saveTask: Task<Void, Never>?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func vectors(for files: [(String, FileStat?)]) -> [[Float]?] {
        let entries = loadedEntries()
        return files.map { path, stat in
            guard let stat, let entry = entries[path], entry.size == stat.size, entry.modified == stat.modified else { return nil }
            return entry.vector.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
    }

    func store(_ fresh: [(String, FileStat, [Float])]) {
        var entries = loadedEntries()
        for (path, stat, vector) in fresh {
            entries[path] = Entry(size: stat.size, modified: stat.modified,
                                  vector: vector.withUnsafeBufferPointer { Data(buffer: $0) })
        }
        self.entries = entries
        scheduleSave()
    }

    var count: Int { loadedEntries().count }

    /// 저장은 잠시 모았다가 한 번에 한다.
    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            self.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard var entries else { return }
        // 지워진 파일의 특징값은 버린다.
        entries = entries.filter { FileManager.default.fileExists(atPath: $0.key) }
        self.entries = entries
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try encoder.encode(Storage(version: Self.version, entries: entries)).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Chaja: 이미지 특징값 캐시 저장 실패 — \(error.localizedDescription)")
        }
    }

    private func loadedEntries() -> [String: Entry] {
        if let entries { return entries }
        var loaded: [String: Entry] = [:]
        if let data = try? Data(contentsOf: fileURL),
           let storage = try? PropertyListDecoder().decode(Storage.self, from: data),
           storage.version == Self.version {
            loaded = storage.entries
        }
        entries = loaded
        return loaded
    }
}
