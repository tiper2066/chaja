import AppKit

enum PermissionService {
    /// TCC 데이터베이스는 전체 디스크 접근 권한이 있어야 열린다. `isReadableFile`은 POSIX 권한만 보므로 실제로 열어본다.
    static var hasFullDiskAccess: Bool {
        let url = URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC/TCC.db")
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        try? handle.close()
        return true
    }

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
