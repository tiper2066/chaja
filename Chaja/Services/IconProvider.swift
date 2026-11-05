import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// 리스트용 아이콘은 파일마다 디스크를 읽지 않도록 콘텐츠 유형별로 캐시한다.
/// 앱·폴더처럼 개별 아이콘이 의미 있는 항목만 파일 경로로 가져온다.
enum IconProvider {
    private static let typeCache = NSCache<NSString, NSImage>()
    private static let fileCache = NSCache<NSString, NSImage>()

    static func icon(for item: FileItem) -> NSImage {
        if needsPerFileIcon(item) {
            if let cached = fileCache.object(forKey: item.path as NSString) { return cached }
            let image = NSWorkspace.shared.icon(forFile: item.path)
            fileCache.setObject(image, forKey: item.path as NSString)
            return image
        }
        let key = (item.contentType ?? "public.data") as NSString
        if let cached = typeCache.object(forKey: key) { return cached }
        let type = item.contentType.flatMap(UTType.init) ?? (item.isFolder ? .folder : .data)
        let image = NSWorkspace.shared.icon(for: type)
        typeCache.setObject(image, forKey: key)
        return image
    }

    private static func needsPerFileIcon(_ item: FileItem) -> Bool {
        guard let identifier = item.contentType, let type = UTType(identifier) else { return false }
        return type.conforms(to: .application) || type.conforms(to: .package) || type == .volume
    }
}

/// Quick Look 썸네일. 이미지·동영상·문서처럼 미리보기가 의미 있는 종류에만 쓴다.
enum ThumbnailProvider {
    private static let cache = NSCache<NSString, NSImage>()

    static func supportsThumbnail(_ item: FileItem) -> Bool {
        switch item.kind {
        case .image, .movie, .document: true
        default: false
        }
    }

    static func thumbnail(for item: FileItem, size: CGFloat, scale: CGFloat = 2) async -> NSImage? {
        let key = "\(item.path)#\(Int(size))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let request = QLThumbnailGenerator.Request(
            fileAt: item.url, size: CGSize(width: size, height: size),
            scale: scale, representationTypes: .thumbnail
        )
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        let image = representation.nsImage
        cache.setObject(image, forKey: key)
        return image
    }
}
