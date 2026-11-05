import Foundation
import Testing
@testable import Chaja

struct FileSystemScannerTests {
    private func makeFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "ChajaScan-\(UUID().uuidString)")
        let package = root.appending(path: "Sample.app/Contents")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: root.appending(path: "visible-target.txt"))
        try Data("b".utf8).write(to: root.appending(path: ".hidden-target.txt"))
        try Data("c".utf8).write(to: package.appending(path: "inside-target.txt"))
        return root
    }

    private func scanNames(_ root: URL, exclusions: ExclusionRules = .none,
                           configure: (inout SearchCriteria) -> Void) async -> Set<String> {
        var criteria = SearchCriteria()
        criteria.scope = .folder(root)
        criteria.text = "target"
        configure(&criteria)
        var names = Set<String>()
        for await batch in FileSystemScanner.scan(criteria: criteria, exclusions: exclusions, limit: 100) {
            names.formUnion(batch.map(\.name))
        }
        return names
    }

    @Test func skipsHiddenAndPackagesByDefault() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(await scanNames(root) { _ in } == ["visible-target.txt"])
    }

    @Test func includesHiddenFilesWhenEnabled() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(await scanNames(root) { $0.includeHidden = true } == ["visible-target.txt", ".hidden-target.txt"])
    }

    @Test func includesPackageContentsWhenEnabled() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(await scanNames(root) { $0.searchPackages = true } == ["visible-target.txt", "inside-target.txt"])
    }

    @Test func skipsExcludedFolders() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let modules = root.appending(path: "node_modules/pkg")
        try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
        try Data("d".utf8).write(to: modules.appending(path: "module-target.txt"))

        #expect(await scanNames(root) { $0.includeHidden = true }.contains("module-target.txt"))
        let excluded = await scanNames(root, exclusions: ExclusionRules(entries: ["node_modules"])) { $0.includeHidden = true }
        #expect(excluded == ["visible-target.txt", ".hidden-target.txt"])
    }

    @Test func matchesTagsAndWhereFroms() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var tagged = root.appending(path: "tagged-target.txt")
        try Data("e".utf8).write(to: tagged)
        var values = URLResourceValues()
        values.tagNames = ["업무"]
        try tagged.setResourceValues(values)

        let downloaded = root.appending(path: "downloaded-target.txt")
        try Data("f".utf8).write(to: downloaded)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["https://drive.google.com/file/1", "https://www.google.com/"],
                                                       format: .binary, options: 0)
        _ = plist.withUnsafeBytes {
            setxattr(downloaded.path, "com.apple.metadata:kMDItemWhereFroms", $0.baseAddress, plist.count, 0, 0)
        }

        #expect(await scanNames(root) { $0.tags = ["업무", "개인"] } == ["tagged-target.txt"])
        #expect(await scanNames(root) { $0.whereFrom = "DRIVE.google" } == ["downloaded-target.txt"])
        #expect(await scanNames(root) { $0.whereFrom = "kakao" }.isEmpty)
    }
}
