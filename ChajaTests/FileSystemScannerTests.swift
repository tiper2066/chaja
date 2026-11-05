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

    private func scanNames(_ root: URL, configure: (inout SearchCriteria) -> Void) async -> Set<String> {
        var criteria = SearchCriteria()
        criteria.scope = .folder(root)
        criteria.text = "target"
        configure(&criteria)
        var names = Set<String>()
        for await batch in FileSystemScanner.scan(criteria: criteria, limit: 100) {
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
}
