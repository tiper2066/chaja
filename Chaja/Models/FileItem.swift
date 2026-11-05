import Foundation

nonisolated struct FileItem: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let size: Int64?
    let created: Date?
    let modified: Date?
    let contentType: String?
    let kindDescription: String
    let isFolder: Bool
    let kind: FileKind?

    init(url: URL, name: String? = nil, size: Int64?, created: Date?, modified: Date?,
         contentType: String?, kindDescription: String?, isFolder: Bool) {
        self.url = url
        self.name = name ?? url.lastPathComponent
        self.size = isFolder ? nil : size
        self.created = created
        self.modified = modified
        self.contentType = contentType
        self.isFolder = isFolder
        self.kind = FileKind.classify(contentType: contentType, fileExtension: url.pathExtension)
        self.kindDescription = kindDescription ?? (isFolder ? "폴더" : url.pathExtension.uppercased())
    }

    var id: String { url.path }
    var path: String { url.path }

    var displayPath: String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    var parentDisplayPath: String {
        (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }

    // Table 정렬용. 값이 없는 항목은 맨 뒤(오름차순 기준 맨 앞)로 보낸다.
    var sortSize: Int64 { size ?? -1 }
    var sortModified: Date { modified ?? .distantPast }
    var sortCreated: Date { created ?? .distantPast }

    var sizeText: String {
        guard let size else { return "--" }
        return size.formatted(.byteCount(style: .file))
    }
}
