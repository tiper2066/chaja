import CryptoKit
import Foundation

/// 내용이 완전히 같은 파일을 찾는다.
/// 크기가 같은 파일끼리 → 앞·뒤 64KB 해시가 같은 파일끼리 → 전체 SHA-256이 같은 파일끼리 순서로 좁혀, 대부분의 파일은 전체를 읽지 않는다.
nonisolated enum DuplicateFinder {
    static let sampleSize = 64 * 1024
    private static let chunkSize = 1 << 20

    private struct Candidate: Sendable {
        let item: FileItem
        let size: Int64
    }

    @concurrent
    static func findDuplicates(
        in items: [FileItem], minimumSize: Int64 = 1,
        progress: @escaping @Sendable (AnalysisProgress) -> Void = { _ in }
    ) async throws -> AnalysisReport {
        progress(AnalysisProgress(message: "파일 크기 확인 중…", fraction: nil))
        var skipped = 0
        var seenPaths = Set<String>()
        var seenIdentities = Set<FileIdentity>()
        var bySize: [Int64: [Candidate]] = [:]
        for item in items {
            try Task.checkCancellation()
            guard seenPaths.insert(item.path).inserted,
                  let stat = FileStat(path: item.path), stat.isRegularFile, stat.size >= max(minimumSize, 1) else { continue }
            if stat.isDataless {
                skipped += 1
                continue
            }
            guard seenIdentities.insert(stat.identity).inserted else { continue }
            bySize[stat.size, default: []].append(Candidate(item: item, size: stat.size))
        }
        let examined = bySize.values.reduce(0) { $0 + $1.count }

        // 1차: 앞·뒤 일부만 읽어 비교. 128KB 이하 파일은 이것만으로 전체 내용이 확정된다.
        let sameSize = bySize.values.filter { $0.count > 1 }.flatMap { $0 }
        let sampled = ProgressCounter()
        let samples = try await AnalysisConcurrency.reporting(
            sampled, total: Int64(sameSize.count),
            message: { "크기가 같은 파일 비교 중 (\($0.formatted()) / \(sameSize.count.formatted()))" },
            to: progress
        ) {
            try await AnalysisConcurrency.map(sameSize) { candidate -> String? in
                defer { sampled.add(1) }
                return try sampleDigest(path: candidate.item.path, size: candidate.size)
            }
        }
        var bySample: [String: [Candidate]] = [:]
        for (candidate, digest) in zip(sameSize, samples) {
            guard let digest else { skipped += 1; continue }
            bySample["\(candidate.size)-\(digest)", default: []].append(candidate)
        }

        var confirmed: [String: [Candidate]] = [:]
        var needsFullHash: [Candidate] = []
        for (key, group) in bySample where group.count > 1 {
            if group[0].size <= Int64(sampleSize * 2) {
                confirmed[key] = group
            } else {
                needsFullHash.append(contentsOf: group)
            }
        }

        // 2차: 앞·뒤가 같은 큰 파일만 전체를 읽어 확정.
        let totalBytes = needsFullHash.reduce(Int64(0)) { $0 + $1.size }
        let hashedBytes = ProgressCounter()
        let fullDigests = try await AnalysisConcurrency.reporting(
            hashedBytes, total: totalBytes,
            message: { "전체 내용 비교 중 (\(byteText($0)) / \(byteText(totalBytes)))" },
            to: progress
        ) {
            try await AnalysisConcurrency.map(needsFullHash) { candidate -> String? in
                try fullDigest(path: candidate.item.path, counter: hashedBytes)
            }
        }
        for (candidate, digest) in zip(needsFullHash, fullDigests) {
            guard let digest else { skipped += 1; continue }
            confirmed["\(candidate.size)-\(digest)", default: []].append(candidate)
        }

        let groups = confirmed.compactMap { key, members -> FileGroup? in
            guard members.count > 1 else { return nil }
            return FileGroup(id: key, files: orderedForKeeping(members.map(\.item)))
        }
        .sorted { wastedBytes($0) > wastedBytes($1) }
        return AnalysisReport(groups: groups, examined: examined, skipped: skipped)
    }

    /// 가장 먼저 만들어진 파일을 원본으로 보고 맨 앞에 둔다. 생성일이 같으면 경로가 짧은 쪽.
    static func orderedForKeeping(_ items: [FileItem]) -> [FileItem] {
        items.sorted { a, b in
            let aDate = a.created ?? .distantFuture
            let bDate = b.created ?? .distantFuture
            if aDate != bDate { return aDate < bDate }
            if a.path.count != b.path.count { return a.path.count < b.path.count }
            return a.path < b.path
        }
    }

    static func wastedBytes(_ group: FileGroup) -> Int64 {
        (group.files.first?.size ?? 0) * Int64(group.files.count - 1)
    }

    // MARK: - 해시

    /// 앞 64KB와 마지막 64KB의 해시. 읽는 도중 파일이 바뀌었거나 읽을 수 없으면 nil.
    static func sampleDigest(path: String, size: Int64) throws -> String? {
        try Task.checkCancellation()
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: sampleSize, alignment: 16)
        defer { buffer.deallocate() }

        var hasher = SHA256()
        let headCount = Int(min(size, Int64(sampleSize)))
        guard readFully(fd, buffer, count: headCount, offset: 0) else { return nil }
        hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[0..<headCount]))
        if size > Int64(sampleSize) {
            guard readFully(fd, buffer, count: sampleSize, offset: off_t(size - Int64(sampleSize))) else { return nil }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(buffer))
        }
        return hex(hasher.finalize())
    }

    /// 전체 내용의 SHA-256. 큰 파일이 디스크 캐시를 밀어내지 않도록 캐시를 거치지 않고 읽는다.
    static func fullDigest(path: String, counter: ProgressCounter? = nil) throws -> String? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: chunkSize, alignment: 16)
        defer { buffer.deallocate() }

        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let count = read(fd, buffer.baseAddress, chunkSize)
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if count == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[0..<count]))
            counter?.add(Int64(count))
        }
        return hex(hasher.finalize())
    }

    private static func readFully(_ fd: Int32, _ buffer: UnsafeMutableRawBufferPointer, count: Int, offset: off_t) -> Bool {
        var done = 0
        while done < count {
            let result = pread(fd, buffer.baseAddress! + done, count - done, offset + off_t(done))
            if result < 0, errno == EINTR { continue }
            guard result > 0 else { return false }
            done += result
        }
        return true
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func byteText(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }
}
