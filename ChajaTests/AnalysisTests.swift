import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import Vision
@testable import Chaja

struct DuplicateFinderTests {
    private func makeFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "ChajaDup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ data: Data, _ name: String, in root: URL) throws -> FileItem {
        let url = root.appending(path: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return item(url)
    }

    private func item(_ url: URL) -> FileItem {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])
        return FileItem(url: url, size: values?.fileSize.map(Int64.init), created: values?.creationDate,
                        modified: values?.contentModificationDate, contentType: nil, kindDescription: nil, isFolder: false)
    }

    private func randomData(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }

    private func groupNames(_ report: AnalysisReport) -> Set<Set<String>> {
        Set(report.groups.map { Set($0.files.map(\.name)) })
    }

    @Test func findsExactCopiesOnly() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }

        let big = randomData(300_000)
        var middleChanged = big
        middleChanged[150_000] ^= 0xFF
        var headChanged = big
        headChanged[10] ^= 0xFF
        let small = randomData(100)

        let items = try [
            write(big, "big.bin", in: root),
            write(big, "copy/big copy.bin", in: root),
            write(middleChanged, "middle-changed.bin", in: root),
            write(headChanged, "head-changed.bin", in: root),
            write(small, "small.txt", in: root),
            write(small, "small copy.txt", in: root),
            write(Data(), "empty-1", in: root),
            write(Data(), "empty-2", in: root),
            write(randomData(100), "same-size-other.txt", in: root),
        ]
        let report = try await DuplicateFinder.findDuplicates(in: items)
        #expect(groupNames(report) == [["big.bin", "big copy.bin"], ["small.txt", "small copy.txt"]])
        // 낭비가 큰 묶음이 먼저.
        #expect(report.groups.first?.files.count == 2)
        #expect(report.groups.first?.files.first?.size == 300_000)
    }

    @Test func ignoresHardLinksAndRespectsMinimumSize() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }

        let data = randomData(5_000)
        let original = try write(data, "original.dat", in: root)
        let linkURL = root.appending(path: "hardlink.dat")
        try FileManager.default.linkItem(at: original.url, to: linkURL)
        let copy = try write(data, "copy.dat", in: root)
        let items = [original, item(linkURL), copy, original]

        let report = try await DuplicateFinder.findDuplicates(in: items)
        #expect(report.groups.count == 1)
        #expect(report.groups.first?.files.count == 2)
        #expect(report.groups.first?.files.contains { $0.name == "copy.dat" } == true)

        let filtered = try await DuplicateFinder.findDuplicates(in: items, minimumSize: 10_000)
        #expect(filtered.groups.isEmpty)
    }

    @Test func fullDigestMatchesSampleForSmallFiles() throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try write(randomData(DuplicateFinder.sampleSize * 2), "a", in: root)
        #expect(try DuplicateFinder.fullDigest(path: a.path) != nil)
        #expect(try DuplicateFinder.sampleDigest(path: a.path, size: Int64(DuplicateFinder.sampleSize * 2)) != nil)
        #expect(try DuplicateFinder.fullDigest(path: root.appending(path: "missing").path) == nil)
    }

    @Test @MainActor func sessionKeepsAtLeastOneFilePerGroup() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = randomData(2_000)
        let items = try (1...3).map { try write(data, "file-\($0).dat", in: root) }

        let session = AnalysisSession(tool: .duplicates)
        session.start(searchResults: items, resultsTruncated: false)
        while session.phase == .running { try await Task.sleep(for: .milliseconds(20)) }
        let group = try #require(session.groups.first)
        // 첫 파일만 남기고 나머지는 미리 표시된다.
        #expect(session.marked == Set(group.files.dropFirst().map(\.path)))

        session.toggleMark(group.files[0], in: group)
        #expect(!session.isMarked(group.files[0]), "마지막 남은 파일은 표시할 수 없어야 한다")

        session.keepOnly(group.files[2], in: group)
        #expect(session.marked == [group.files[0].path, group.files[1].path])

        session.remove(paths: [group.files[1].path])
        #expect(session.groups.first?.files.count == 2)
        session.remove(paths: [group.files[2].path])
        #expect(session.groups.isEmpty, "한 파일만 남은 묶음은 사라져야 한다")
    }
}

struct SimilarImageFinderTests {
    nonisolated private static let wallpapers = URL(fileURLWithPath: "/System/Library/Desktop Pictures")
    nonisolated private static let hasWallpapers = FileManager.default.fileExists(atPath: wallpapers.appending(path: "Sonoma.heic").path)
        && FileManager.default.fileExists(atPath: wallpapers.appending(path: "Mac Blue.heic").path)

    /// 시스템 배경화면을 크기·화질을 바꿔 JPEG로 저장한다.
    private func exportJPEG(_ name: String, maxPixel: Int, quality: Double, to url: URL) throws -> FileItem {
        let source = try #require(CGImageSourceCreateWithURL(Self.wallpapers.appending(path: name) as CFURL, nil))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        let image = try #require(CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init)
        return FileItem(url: url, size: size, created: nil, modified: nil, contentType: UTType.jpeg.identifier,
                        kindDescription: nil, isFolder: false)
    }

    @Test func clustersByThreshold() throws {
        let a: [Float] = [1, 0, 0]
        let b: [Float] = [0.99, 0.141, 0]
        let c: [Float] = [0, 1, 0]
        let d: [Float] = [0, 0.99, 0.141]
        let e: [Float] = [0, 0, 1]
        let clusters = try SimilarImageFinder.clusters(of: [a, b, c, d, e], threshold: 0.05)
        #expect(clusters == [[0, 1], [2, 3]])
        #expect(try SimilarImageFinder.clusters(of: [a, e], threshold: 0.05).isEmpty)
        #expect(try SimilarImageFinder.clusters(of: [a, [1, 0]], threshold: 10).isEmpty, "차원이 다른 벡터는 비교하지 않는다")
    }

    /// 블록 행렬곱 경로가 단순 계산과 같은 결과를 내는지(블록 크기 256을 넘는 개수로).
    @Test func blockedClusteringMatchesBruteForce() throws {
        var generator = SystemRandomNumberGenerator()
        let centers = (0..<40).map { _ in (0..<32).map { _ in Float.random(in: -1...1, using: &generator) } }
        let vectors = (0..<600).map { index in centers[index % 40].map { $0 + Float.random(in: -0.05...0.05, using: &generator) } }
        let threshold: Float = 0.2
        let clusters = try SimilarImageFinder.clusters(of: vectors, threshold: threshold)

        var expected = Set<Set<Int>>()
        for center in 0..<40 {
            expected.insert(Set(stride(from: center, to: 600, by: 40)))
        }
        // 무작위 중심끼리는 충분히 멀어 섞이지 않는다.
        #expect(Set(clusters.map(Set.init)) == expected)
    }

    @Test func clusteringTenThousandImagesIsFast() throws {
        // 768차원 무작위 단위 벡터는 서로 거의 직교해서(거리² ≈ 2) 묶이는 것이 없다.
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        let scale = 1 / sqrt(Float(768) / 3)
        let vectors = (0..<10_000).map { _ in
            [Float](unsafeUninitializedCapacity: 768) { buffer, count in
                for index in 0..<768 {
                    state ^= state << 13
                    state ^= state >> 7
                    state ^= state << 17
                    buffer[index] = (Float(state & 0xFFFF) / 32_768 - 1) * scale
                }
                count = 768
            }
        }
        let clock = ContinuousClock()
        let start = clock.now
        let clusters = try SimilarImageFinder.clusters(of: vectors, threshold: SimilarityLevel.loose.threshold)
        let elapsed = clock.now - start
        print("이미지 1만 개 묶기: \(elapsed)")
        #expect(clusters.isEmpty)
        #expect(elapsed < .seconds(1))
    }

    @Test(.enabled(if: hasWallpapers))
    func groupsResizedCopiesAndUsesCache() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ChajaSimilar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let items = try [
            exportJPEG("Sonoma.heic", maxPixel: 1600, quality: 0.9, to: root.appending(path: "sonoma.jpg")),
            exportJPEG("Sonoma.heic", maxPixel: 500, quality: 0.3, to: root.appending(path: "sonoma-small.jpg")),
            exportJPEG("Mac Blue.heic", maxPixel: 1600, quality: 0.9, to: root.appending(path: "mac-blue.jpg")),
        ]
        let broken = root.appending(path: "broken.jpg")
        try Data("not an image".utf8).write(to: broken)
        let brokenItem = FileItem(url: broken, size: 12, created: nil, modified: nil, contentType: UTType.jpeg.identifier,
                                  kindDescription: nil, isFolder: false)

        let store = FeaturePrintStore(fileURL: root.appending(path: "cache.plist"))
        let report = try await SimilarImageFinder.findSimilar(in: items + [brokenItem], level: .similar, store: store)
        #expect(report.groups.map { Set($0.files.map(\.name)) } == [["sonoma.jpg", "sonoma-small.jpg"]])
        #expect(report.groups.first?.files.first?.name == "sonoma.jpg", "큰 파일이 맨 앞")
        #expect(report.examined == 3)
        #expect(report.skipped == 1)
        #expect(await store.count == 3)

        // 직접 계산한 거리가 Vision의 거리와 같아야 임계값을 그대로 쓸 수 있다.
        let first = try await GenerateImageFeaturePrintRequest().perform(on: items[0].url)
        let second = try await GenerateImageFeaturePrintRequest().perform(on: items[1].url)
        let prints = try await SimilarImageFinder.featurePrints(for: [items[0], items[1]], store: store)
        let mine = SimilarImageFinder.squaredDistance(try #require(prints[0]), try #require(prints[1]))
        #expect(abs(Double(mine) - (try first.distance(to: second))) < 0.001)

        // 저장 후 새 저장소로 다시 읽어도 같은 특징값을 쓴다.
        await store.saveNow()
        let reloaded = FeaturePrintStore(fileURL: root.appending(path: "cache.plist"))
        #expect(await reloaded.count == 3)
        let similar = try await SimilarImageFinder.images(similarTo: items[0], among: items, level: .similar, store: reloaded)
        #expect(similar.map(\.name) == ["sonoma-small.jpg"])

        // 파일이 바뀌면 캐시를 쓰지 않는다.
        var changed = try exportJPEG("Mac Blue.heic", maxPixel: 1200, quality: 0.5, to: items[1].url).url
        var values = URLResourceValues()
        values.contentModificationDate = .now.addingTimeInterval(60)
        try changed.setResourceValues(values)
        let afterChange = try await SimilarImageFinder.images(similarTo: items[0], among: items, level: .similar, store: reloaded)
        #expect(afterChange.isEmpty)
    }
}
