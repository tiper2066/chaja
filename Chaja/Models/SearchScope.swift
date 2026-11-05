import Foundation

nonisolated enum SearchScope: Hashable, Codable, Sendable {
    case computer, home, desktop, downloads, documents
    case folder(URL)

    static let presets: [SearchScope] = [.computer, .home, .desktop, .downloads, .documents]

    var title: String {
        switch self {
        case .computer: "전체 Mac"
        case .home: "홈 폴더"
        case .desktop: "데스크탑"
        case .downloads: "다운로드"
        case .documents: "문서"
        case .folder(let url): url.lastPathComponent
        }
    }

    var symbol: String {
        switch self {
        case .computer: "laptopcomputer"
        case .home: "house"
        case .desktop: "menubar.dock.rectangle"
        case .downloads: "arrow.down.circle"
        case .documents: "doc"
        case .folder: "folder"
        }
    }

    /// nil이면 이 맥 전체.
    var url: URL? {
        let fm = FileManager.default
        switch self {
        case .computer: return nil
        case .home: return fm.homeDirectoryForCurrentUser
        case .desktop: return fm.urls(for: .desktopDirectory, in: .userDomainMask).first
        case .downloads: return fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
        case .documents: return fm.urls(for: .documentDirectory, in: .userDomainMask).first
        case .folder(let url): return url
        }
    }

    var isCustomFolder: Bool {
        if case .folder = self { return true }
        return false
    }
}
